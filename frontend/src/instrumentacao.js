// Carregado antes do servidor (`node --import ./src/instrumentacao.js src/server.js`), para que
// a instrumentação do http entre antes do Express. Sem OTEL_EXPORTER_OTLP_ENDPOINT, não faz nada.
import { OTLPMetricExporter } from '@opentelemetry/exporter-metrics-otlp-proto';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-proto';
import { PeriodicExportingMetricReader } from '@opentelemetry/sdk-metrics';

import { iniciarTelemetria, validarAmostragem, validarEndpoint } from './telemetria.js';

const env = process.env;

function configurar() {
  if (!env.OTEL_EXPORTER_OTLP_ENDPOINT) return null;
  const endpoint = validarEndpoint(env.OTEL_EXPORTER_OTLP_ENDPOINT);
  return iniciarTelemetria({
    exportadorSpans: new OTLPTraceExporter({ url: `${endpoint}/v1/traces` }),
    leitorMetricas: new PeriodicExportingMetricReader({
      exporter: new OTLPMetricExporter({ url: `${endpoint}/v1/metrics` }),
    }),
    servico: env.OTEL_SERVICE_NAME || 'cybersec-frontend',
    ambiente: env.NODE_ENV === 'production' ? 'prod' : 'dev',
    amostragem: validarAmostragem(env.OTEL_TRACES_SAMPLER_ARG),
  });
}

let telemetria = null;
try {
  telemetria = configurar();
} catch (err) {
  // Só a mensagem de configuração, escrita por nós: nenhum valor de variável é ecoado.
  console.error(err.message);
  process.exit(1);
}

if (telemetria) {
  // O ECS encerra a task com SIGTERM: envia o que falta antes de sair.
  process.once('SIGTERM', async () => {
    await telemetria.encerrar();
    process.exit(143);
  });
}
