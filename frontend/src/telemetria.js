// Telemetria OpenTelemetry: traces e métricas em OTLP, sem dado sensível (ADR-0031).
//
// Tudo o que sai passa por uma lista de permissão de atributos, e não por uma lista de bloqueio:
// um atributo novo de uma instrumentação (URL, IP, cabeçalho) não é exportado até ser revisado e
// incluído aqui. Mensagem e pilha de exceções também ficam de fora; só o tipo é exportado.
import { context, metrics, propagation, trace } from '@opentelemetry/api';
import { AsyncLocalStorageContextManager } from '@opentelemetry/context-async-hooks';
import { W3CTraceContextPropagator } from '@opentelemetry/core';
import { registerInstrumentations } from '@opentelemetry/instrumentation';
import { HttpInstrumentation } from '@opentelemetry/instrumentation-http';
import { UndiciInstrumentation } from '@opentelemetry/instrumentation-undici';
import { resourceFromAttributes } from '@opentelemetry/resources';
import { createAllowListAttributesProcessor, MeterProvider } from '@opentelemetry/sdk-metrics';
import {
  BatchSpanProcessor,
  ParentBasedSampler,
  TraceIdRatioBasedSampler,
  TracerProvider,
} from '@opentelemetry/sdk-trace';

// Rota como modelo, nunca o caminho real; sem query string, IP, user agent nem cabeçalhos.
// Nomes estáveis e antigos da convenção semântica (a instrumentação emite um ou outro).
export const ATRIBUTOS_PERMITIDOS = new Set([
  'http.request.method',
  'http.method',
  'http.route',
  'http.response.status_code',
  'http.status_code',
  'url.scheme',
  'http.scheme',
  'network.protocol.version',
  'http.flavor',
  'error.type',
]);
const ATRIBUTOS_EXCECAO = new Set(['exception.type']);
const SPAN_KIND_SERVER = 1;

function filtrar(atributos, permitidos) {
  return Object.fromEntries(
    Object.entries(atributos ?? {}).filter(([chave]) => permitidos.has(chave)),
  );
}

function nomeSeguro(span, atributos) {
  // Span de servidor sem rota pode carregar o caminho no nome.
  if (span.kind === SPAN_KIND_SERVER && !('http.route' in atributos)) {
    return String(atributos['http.request.method'] ?? atributos['http.method'] ?? 'HTTP');
  }
  return span.name;
}

// Cópia do span só com atributos permitidos, sem mensagem de erro nem pilha. Herda o resto
// (contexto, horários, recurso) do original pelo protótipo, sem alterá-lo.
export function sanitizarSpan(span) {
  const atributos = filtrar(span.attributes, ATRIBUTOS_PERMITIDOS);
  const eventos = span.events
    .filter((evento) => evento.name === 'exception')
    .map((evento) => ({ ...evento, attributes: filtrar(evento.attributes, ATRIBUTOS_EXCECAO) }));
  return Object.create(span, {
    name: { value: nomeSeguro(span, atributos), enumerable: true },
    attributes: { value: atributos, enumerable: true },
    events: { value: eventos, enumerable: true },
    links: { value: span.links.map((link) => ({ context: link.context })), enumerable: true },
    // A mensagem do status costuma ser a da exceção.
    status: { value: { code: span.status.code }, enumerable: true },
  });
}

export class ExportadorFiltrado {
  constructor(destino) {
    this.destino = destino;
  }

  export(spans, callback) {
    this.destino.export(spans.map(sanitizarSpan), callback);
  }

  shutdown() {
    return this.destino.shutdown();
  }

  forceFlush() {
    return this.destino.forceFlush?.() ?? Promise.resolve();
  }
}

// O frontend é a borda: um `traceparent` vindo do navegador não é aceito (o cliente escolheria o
// trace id e forçaria amostragem). O contexto só é injetado nas chamadas ao backend.
export class PropagadorSoSaida {
  constructor() {
    this.w3c = new W3CTraceContextPropagator();
  }

  inject(ctx, carrier, setter) {
    this.w3c.inject(ctx, carrier, setter);
  }

  extract(ctx) {
    return ctx;
  }

  fields() {
    return this.w3c.fields();
  }
}

// "http://10.0.0.10:4318" -> origem normalizada; credencial, caminho ou query interrompem a
// inicialização (uma credencial na URL acabaria em mensagens de erro do exportador).
export function validarEndpoint(texto) {
  let url;
  try {
    url = new URL(texto);
  } catch {
    throw new Error('OTEL_EXPORTER_OTLP_ENDPOINT inválido.');
  }
  const soOrigem =
    ['http:', 'https:'].includes(url.protocol) &&
    url.pathname === '/' &&
    !url.search &&
    !url.hash &&
    !url.username &&
    !url.password;
  if (!soOrigem) {
    throw new Error('OTEL_EXPORTER_OTLP_ENDPOINT deve ser só esquema, host e porta.');
  }
  return url.origin;
}

export function validarAmostragem(texto) {
  if (texto === undefined || texto === '') return 1;
  const fracao = Number(texto);
  if (!Number.isFinite(fracao) || fracao < 0 || fracao > 1) {
    throw new Error('OTEL_TRACES_SAMPLER_ARG deve estar entre 0 e 1.');
  }
  return fracao;
}

export function iniciarTelemetria({
  exportadorSpans,
  leitorMetricas,
  servico = 'cybersec-frontend',
  ambiente = 'dev',
  amostragem = 1,
}) {
  const resource = resourceFromAttributes({
    'service.name': servico,
    'deployment.environment.name': ambiente,
  });
  const tracerProvider = new TracerProvider({
    resource,
    sampler: new ParentBasedSampler({ root: new TraceIdRatioBasedSampler(amostragem) }),
    spanProcessors: [new BatchSpanProcessor({ exporter: new ExportadorFiltrado(exportadorSpans) })],
  });
  const meterProvider = new MeterProvider({
    resource,
    readers: [leitorMetricas],
    views: [
      {
        instrumentName: '*',
        attributesProcessors: [createAllowListAttributesProcessor([...ATRIBUTOS_PERMITIDOS])],
      },
    ],
  });

  context.setGlobalContextManager(new AsyncLocalStorageContextManager().enable());
  propagation.setGlobalPropagator(new PropagadorSoSaida());
  trace.setGlobalTracerProvider(tracerProvider);
  metrics.setGlobalMeterProvider(meterProvider);
  const desregistrar = registerInstrumentations({
    tracerProvider,
    meterProvider,
    instrumentations: [
      new HttpInstrumentation({
        ignoreIncomingRequestHook: (req) => req.url === '/health',
        // Chamadas de saída do frontend são por fetch (undici); o http de saída é só o exportador.
        disableOutgoingRequestInstrumentation: true,
      }),
      new UndiciInstrumentation(),
    ],
  });

  return {
    tracerProvider,
    meterProvider,
    async encerrar() {
      desregistrar();
      await Promise.allSettled([tracerProvider.shutdown(), meterProvider.shutdown()]);
    },
  };
}
