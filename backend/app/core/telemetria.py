"""Telemetria OpenTelemetry: traces e métricas exportados em OTLP, sem dado sensível (ADR-0031).

Tudo o que sai passa por uma lista de permissão de atributos, e não por uma lista de bloqueio:
um atributo novo de uma instrumentação (URL, IP, SQL, cabeçalho) não é exportado até ser
revisado e incluído aqui. A mensagem e a pilha das exceções também ficam de fora, porque podem
conter dados da requisição; só o tipo da exceção é exportado.
"""

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Final

from fastapi import FastAPI
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.propagate import set_global_textmap
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import MetricReader, PeriodicExportingMetricReader
from opentelemetry.sdk.metrics.view import View
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import Event, ReadableSpan, TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, SpanExporter, SpanExportResult
from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased
from opentelemetry.trace import Link, Span, SpanKind, Status, StatusCode
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
from opentelemetry.util.types import AttributeValue
from sqlalchemy import Engine, event
from sqlalchemy.engine import Connection, ExceptionContext, ExecutionContext

from app.core.config import Settings

# Rota como modelo (/pacientes/{id_publico}), nunca o caminho real; sem query string, IP do
# cliente, user agent, cabeçalhos, texto SQL ou parâmetros. Nomes estáveis e antigos da
# convenção semântica, porque a instrumentação emite um ou outro conforme a versão.
ATRIBUTOS_PERMITIDOS: Final = frozenset(
    {
        "http.request.method",
        "http.method",
        "http.route",
        "http.response.status_code",
        "http.status_code",
        "url.scheme",
        "http.scheme",
        "network.protocol.version",
        "http.flavor",
        "error.type",
        "db.system",
        "db.system.name",
        "db.name",
        "db.namespace",
        "db.operation",
        "db.operation.name",
    }
)
ATRIBUTOS_EXCECAO: Final = frozenset({"exception.type"})
CAMINHOS_IGNORADOS: Final = "health"
# Só a primeira palavra do comando, e só se for uma destas: o resto do SQL nunca sai.
OPERACOES_SQL: Final = frozenset(
    {"SELECT", "INSERT", "UPDATE", "DELETE", "WITH", "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT"}
    | {"RELEASE", "SET", "SHOW", "LOCK", "CALL"}
)
_SPAN_SQL: Final = "_telemetria_span"


def _filtrar(
    atributos: Mapping[str, AttributeValue] | None, permitidos: frozenset[str]
) -> dict[str, AttributeValue]:
    return {chave: valor for chave, valor in (atributos or {}).items() if chave in permitidos}


def _nome_seguro(span: ReadableSpan, atributos: Mapping[str, AttributeValue]) -> str:
    # Span de servidor sem rota (404, método não permitido) pode carregar o caminho no nome.
    if span.kind is SpanKind.SERVER and "http.route" not in atributos:
        metodo = atributos.get("http.request.method") or atributos.get("http.method")
        return str(metodo) if metodo else "HTTP"
    return span.name


def sanitizar_span(span: ReadableSpan) -> ReadableSpan:
    """Cópia do span só com atributos permitidos, sem mensagem de erro nem pilha."""
    atributos = _filtrar(span.attributes, ATRIBUTOS_PERMITIDOS)
    eventos = [
        Event(
            name=evento.name,
            attributes=_filtrar(evento.attributes, ATRIBUTOS_EXCECAO),
            timestamp=evento.timestamp,
        )
        for evento in span.events
        if evento.name == "exception"
    ]
    return ReadableSpan(
        name=_nome_seguro(span, atributos),
        context=span.context,
        parent=span.parent,
        resource=span.resource,
        attributes=atributos,
        events=eventos,
        links=[Link(link.context) for link in span.links],
        kind=span.kind,
        # A descrição do status costuma ser a mensagem da exceção.
        status=Status(span.status.status_code),
        start_time=span.start_time,
        end_time=span.end_time,
        instrumentation_scope=span.instrumentation_scope,
    )


class ExportadorFiltrado(SpanExporter):
    """Sanitiza cada span antes de entregá-lo ao exportador real."""

    def __init__(self, destino: SpanExporter) -> None:
        self._destino = destino

    def export(self, spans: Sequence[ReadableSpan]) -> SpanExportResult:
        return self._destino.export([sanitizar_span(span) for span in spans])

    def shutdown(self) -> None:
        self._destino.shutdown()

    def force_flush(self, timeout_millis: int = 30_000) -> bool:
        return self._destino.force_flush(timeout_millis)


@dataclass(frozen=True)
class Telemetria:
    tracer_provider: TracerProvider
    meter_provider: MeterProvider


def criar_telemetria(
    settings: Settings,
    exportador_spans: SpanExporter | None = None,
    leitor_metricas: MetricReader | None = None,
) -> Telemetria | None:
    """Providers de traces e métricas; None se a telemetria estiver desligada."""
    endpoint = settings.otel_exporter_otlp_endpoint
    if endpoint is None and exportador_spans is None:
        return None
    if exportador_spans is None:
        exportador_spans = OTLPSpanExporter(endpoint=f"{endpoint}/v1/traces")
    if leitor_metricas is None:
        leitor_metricas = PeriodicExportingMetricReader(
            OTLPMetricExporter(endpoint=f"{endpoint}/v1/metrics")
        )
    recurso = Resource.create(
        {
            "service.name": settings.otel_service_name,
            "deployment.environment.name": settings.environment,
        }
    )
    tracer_provider = TracerProvider(
        resource=recurso,
        sampler=ParentBased(TraceIdRatioBased(settings.otel_traces_sampler_arg)),
    )
    tracer_provider.add_span_processor(BatchSpanProcessor(ExportadorFiltrado(exportador_spans)))
    meter_provider = MeterProvider(
        resource=recurso,
        metric_readers=[leitor_metricas],
        views=[View(instrument_name="*", attribute_keys=set(ATRIBUTOS_PERMITIDOS))],
    )
    return Telemetria(tracer_provider=tracer_provider, meter_provider=meter_provider)


def instrumentar(app: FastAPI, engine: Engine, telemetria: Telemetria) -> None:
    # Só o contexto de trace atravessa serviços; baggage não, porque viria de fora sem revisão.
    set_global_textmap(TraceContextTextMapPropagator())
    FastAPIInstrumentor.instrument_app(
        app,
        tracer_provider=telemetria.tracer_provider,
        meter_provider=telemetria.meter_provider,
        excluded_urls=CAMINHOS_IGNORADOS,
        exclude_spans=["receive", "send"],
        http_capture_headers_server_request=[],
        http_capture_headers_server_response=[],
    )
    instrumentar_banco(engine, telemetria.tracer_provider)


def _operacao(comando: str) -> str:
    palavras = comando.split(maxsplit=1)
    primeira = palavras[0].upper() if palavras else ""
    return primeira if primeira in OPERACOES_SQL else "SQL"


def instrumentar_banco(engine: Engine, tracer_provider: TracerProvider) -> None:
    """Um span por comando SQL, com a operação e a duração; sem texto nem parâmetros.

    Feito com os eventos do SQLAlchemy porque a instrumentação oficial ainda não suporta a
    versão 2.1 (ADR-0031). Vale só para o engine recebido, sem alterar `create_engine`.
    """
    tracer = tracer_provider.get_tracer(__name__)
    banco = engine.url.database or "postgres"

    @event.listens_for(engine, "before_cursor_execute")
    def _inicio(
        _conn: Connection,
        _cursor: object,
        comando: str,
        _parametros: object,
        contexto: ExecutionContext | None,
        _varios: bool,
    ) -> None:
        if contexto is None:
            return
        operacao = _operacao(comando)
        span = tracer.start_span(
            f"{operacao} {banco}",
            kind=SpanKind.CLIENT,
            attributes={
                "db.system.name": "postgresql",
                "db.namespace": banco,
                "db.operation.name": operacao,
            },
        )
        setattr(contexto, _SPAN_SQL, span)

    @event.listens_for(engine, "after_cursor_execute")
    def _fim(
        _conn: Connection,
        _cursor: object,
        _comando: str,
        _parametros: object,
        contexto: ExecutionContext | None,
        _varios: bool,
    ) -> None:
        span: Span | None = getattr(contexto, _SPAN_SQL, None)
        if span is not None:
            span.end()

    @event.listens_for(engine, "handle_error")
    def _erro(contexto_erro: ExceptionContext) -> None:
        span: Span | None = getattr(contexto_erro.execution_context, _SPAN_SQL, None)
        if span is not None:
            # Só o tipo: a mensagem do driver pode conter valores da linha.
            span.set_attribute("error.type", type(contexto_erro.original_exception).__name__)
            span.set_status(Status(StatusCode.ERROR))
            span.end()
