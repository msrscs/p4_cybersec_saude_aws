// T12 / THREAT_MODEL I8: telemetria do frontend sem dado sensível (ADR-0031).
import assert from 'node:assert/strict';
import http from 'node:http';
import { after, before, describe, it } from 'node:test';

import { SpanStatusCode, trace } from '@opentelemetry/api';
import {
  AggregationTemporality,
  InMemoryMetricExporter,
  PeriodicExportingMetricReader,
} from '@opentelemetry/sdk-metrics';
import { InMemorySpanExporter } from '@opentelemetry/sdk-trace';

import {
  ATRIBUTOS_PERMITIDOS,
  iniciarTelemetria,
  sanitizarSpan,
  validarAmostragem,
  validarEndpoint,
} from '../src/telemetria.js';

const CPF = '52998224725';
const SENHA = 'Saúde#Recife2026';
const SESSAO = 'token-de-sessao-ficticio-0123456789';
const CSRF = 'csrf-ficticio-abcdef';
const UUID = '6f1c2a8e-1f0b-4c55-9d1e-2b4b9b6b7c11';
const IP = '203.0.113.77';
const TRACE_NAVEGADOR = '4bf92f3577b34da6a3ce929d0e0e4736';

// Instrumentação antes do Express, como o `--import` faz em produção.
const spans = new InMemorySpanExporter();
const metricas = new InMemoryMetricExporter(AggregationTemporality.CUMULATIVE);
const leitor = new PeriodicExportingMetricReader({
  exporter: metricas,
  exportIntervalMillis: 60_000,
});
const telemetria = iniciarTelemetria({ exportadorSpans: spans, leitorMetricas: leitor });
const { createApp } = await import('../src/app.js');

function ouvir(servidor) {
  return new Promise((resolve) => {
    servidor.listen(0, '127.0.0.1', () => resolve(`http://127.0.0.1:${servidor.address().port}`));
  });
}

async function exportado() {
  await telemetria.tracerProvider.forceFlush();
  await telemetria.meterProvider.forceFlush();
  const finalizados = spans.getFinishedSpans();
  const texto = JSON.stringify({
    spans: finalizados.map((s) => ({
      name: s.name,
      attributes: s.attributes,
      events: s.events,
      status: s.status,
      links: s.links,
      resource: s.resource.attributes,
    })),
    metricas: metricas.getMetrics(),
  });
  return { finalizados, texto };
}

describe('telemetria do frontend', () => {
  let backend;
  let frontend;
  let baseUrl;
  const recebidos = [];

  before(async () => {
    backend = http.createServer((req, res) => {
      recebidos.push(req.headers);
      req.resume();
      req.on('end', () => {
        res.writeHead(req.url.startsWith('/pacientes/') ? 500 : 200, {
          'content-type': 'application/json',
          'set-cookie': `__Host-sessao=${SESSAO}; Path=/; HttpOnly; Secure`,
        });
        res.end(JSON.stringify({ cpf: CPF }));
      });
    });
    const apiUrl = await ouvir(backend);
    frontend = createApp({ apiUrl }).listen(0, '127.0.0.1');
    await new Promise((resolve) => frontend.once('listening', resolve));
    baseUrl = `http://127.0.0.1:${frontend.address().port}`;
  });

  after(async () => {
    frontend.close();
    backend.close();
    await telemetria.encerrar();
  });

  it('não exporta CPF, senha, cookies, token, id, IP nem caminho', async () => {
    const cabecalhos = {
      'content-type': 'application/json',
      origin: baseUrl,
      'sec-fetch-site': 'same-origin',
      cookie: `__Host-sessao=${SESSAO}`,
      'x-csrf-token': CSRF,
      'x-forwarded-for': IP,
      'user-agent': `Navegador/${CPF}`,
      traceparent: `00-${TRACE_NAVEGADOR}-00f067aa0ba902b7-01`,
    };
    const login = await fetch(`${baseUrl}/api/auth/login?cpf=${CPF}`, {
      method: 'POST',
      headers: cabecalhos,
      body: JSON.stringify({ cpf: CPF, senha: SENHA }),
    });
    assert.equal(login.status, 200); // o repasse descarta a query string; a telemetria também
    const ok = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: cabecalhos,
      body: JSON.stringify({ cpf: CPF, senha: SENHA }),
    });
    assert.equal(ok.status, 200);
    assert.equal(
      (await fetch(`${baseUrl}/api/pacientes/${UUID}`, { headers: cabecalhos })).status,
      500,
    );
    assert.equal(
      (await fetch(`${baseUrl}/inexistente/${CPF}`, { headers: cabecalhos })).status,
      404,
    );
    assert.equal((await fetch(`${baseUrl}/health`)).status, 200);

    const { finalizados, texto } = await exportado();
    for (const [nome, valor] of Object.entries({ CPF, SENHA, SESSAO, CSRF, UUID, IP })) {
      assert.ok(!texto.includes(valor), `${nome} vazou na telemetria`);
    }
    assert.ok(!texto.includes('/api/'), 'caminho vazou na telemetria');
    assert.ok(!texto.includes('Navegador'), 'user agent vazou na telemetria');

    // Útil: servidor e chamadas ao backend com método e status; /health fica de fora.
    const servidor = finalizados.filter((s) => s.kind === 1);
    const cliente = finalizados.filter((s) => s.kind === 2);
    assert.ok(servidor.length >= 4);
    assert.ok(cliente.some((s) => s.attributes['http.response.status_code'] === 500));
    assert.ok(texto.includes('http.server.request.duration'));
    for (const span of finalizados) {
      for (const chave of Object.keys(span.attributes)) assert.ok(ATRIBUTOS_PERMITIDOS.has(chave));
    }

    // O traceparent do navegador é ignorado; o do backend continua o trace do frontend.
    assert.ok(!texto.includes(TRACE_NAVEGADOR));
    const enviados = recebidos.map((h) => h.traceparent).filter(Boolean);
    assert.ok(enviados.length >= 2);
    for (const tp of enviados) assert.ok(!tp.includes(TRACE_NAVEGADOR));
    const idsFrontend = new Set(servidor.map((s) => s.spanContext().traceId));
    assert.ok(enviados.every((tp) => idsFrontend.has(tp.split('-')[1])));
  });

  it('exceção sai só com o tipo, e o status sem mensagem', async () => {
    const tracer = trace.getTracer('teste');
    tracer.startActiveSpan('manual', (span) => {
      span.recordException(new TypeError(`CPF ${CPF} inválido`));
      span.setStatus({ code: SpanStatusCode.ERROR, message: `falhou para ${CPF}` });
      span.end();
    });
    const { finalizados } = await exportado();
    const manual = sanitizarSpan(finalizados.find((s) => s.name === 'manual'));
    assert.deepEqual(
      manual.events.map((e) => e.attributes),
      [{ 'exception.type': 'TypeError' }],
    );
    assert.deepEqual(manual.status, { code: SpanStatusCode.ERROR });
    assert.ok(!JSON.stringify(manual.events).includes(CPF));
  });
});

describe('sanitizarSpan', () => {
  const base = {
    kind: 1,
    name: `GET /api/pacientes/${UUID}`,
    events: [],
    links: [{ context: { traceId: 'a' }, attributes: { cpf: CPF } }],
    status: { code: 0 },
    spanContext: () => ({ traceId: 'x' }),
  };

  it('servidor sem rota usa só o método no nome', () => {
    const span = sanitizarSpan({
      ...base,
      attributes: { 'http.request.method': 'GET', 'url.path': `/api/pacientes/${UUID}` },
    });
    assert.equal(span.name, 'GET');
    assert.deepEqual(span.attributes, { 'http.request.method': 'GET' });
    assert.deepEqual(span.links, [{ context: { traceId: 'a' } }]);
    assert.equal(span.spanContext().traceId, 'x'); // o resto vem do original
  });

  it('não altera o span original', () => {
    const original = { ...base, attributes: { 'url.full': CPF } };
    sanitizarSpan(original);
    assert.deepEqual(original.attributes, { 'url.full': CPF });
  });
});

describe('configuração da telemetria', () => {
  it('aceita só esquema, host e porta no endpoint', () => {
    assert.equal(validarEndpoint('http://10.0.0.10:4318/'), 'http://10.0.0.10:4318');
    for (const ruim of [
      'ftp://10.0.0.10:4318',
      'http://usuario:senha@10.0.0.10:4318',
      'http://10.0.0.10:4318/v1/traces',
      'http://10.0.0.10:4318?token=x',
      '10.0.0.10',
    ]) {
      assert.throws(
        () => validarEndpoint(ruim),
        (err) => !err.message.includes('senha'),
      );
    }
  });

  it('amostragem entre 0 e 1', () => {
    assert.equal(validarAmostragem(undefined), 1);
    assert.equal(validarAmostragem('0.25'), 0.25);
    for (const ruim of ['-0.1', '1.5', 'abc']) assert.throws(() => validarAmostragem(ruim));
  });
});
