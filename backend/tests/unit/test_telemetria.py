"""T12 / THREAT_MODEL I8: telemetria sem dado sensível (ADR-0031)."""

import json

import pytest
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from opentelemetry.trace import SpanKind, Status, StatusCode
from pydantic import ValidationError
from sqlalchemy import create_engine, text
from sqlalchemy.exc import OperationalError

from app.core.config import Settings, get_settings
from app.core.telemetria import (
    ATRIBUTOS_PERMITIDOS,
    ExportadorFiltrado,
    _operacao,
    criar_telemetria,
    instrumentar_banco,
)

CPF = "52998224725"
SEGREDO = "token-de-sessao-ficticio"


def _exportar(**kwargs: object) -> tuple[dict[str, object], str]:
    destino = InMemorySpanExporter()
    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(ExportadorFiltrado(destino)))
    tracer = provider.get_tracer("teste")
    kind = kwargs.pop("kind", SpanKind.SERVER)
    with tracer.start_as_current_span(
        str(kwargs.pop("nome", "GET /pacientes/{id_paciente}")),
        kind=kind,  # type: ignore[arg-type]
        record_exception=False,
        set_status_on_exception=False,
    ) as span:
        span.set_attributes(kwargs.pop("atributos", {}))  # type: ignore[arg-type]
        if kwargs.pop("excecao", False):
            span.record_exception(ValueError(f"CPF {CPF} inválido"))
            span.set_status(Status(StatusCode.ERROR, f"falhou para {CPF}"))
    (exportado,) = destino.get_finished_spans()
    texto = exportado.to_json()
    return json.loads(texto), texto


def test_so_atributos_permitidos_saem() -> None:
    sensiveis = {
        "url.path": f"/pacientes/{CPF}",
        "url.full": f"https://x/pacientes?cpf={CPF}",
        "url.query": f"cpf={CPF}",
        "http.target": f"/pacientes?cpf={CPF}",
        "client.address": "203.0.113.7",
        "net.peer.ip": "203.0.113.7",
        "user_agent.original": "Mozilla",
        "http.request.header.cookie": (f"__Host-sessao={SEGREDO}",),
        "http.request.header.x_csrf_token": (SEGREDO,),
        "db.statement": "SELECT * FROM app.paciente WHERE cpf_hash = %(p)s",
        "db.query.text": "SELECT 1",
        "enduser.id": CPF,
    }
    permitidos = {"http.route": "/pacientes/{id_paciente}", "http.response.status_code": 200}
    span, texto = _exportar(atributos={**sensiveis, **permitidos})
    assert span["attributes"] == permitidos
    for valor in (CPF, SEGREDO, "203.0.113.7", "SELECT", "Mozilla"):
        assert valor not in texto


def test_excecao_sai_so_com_o_tipo() -> None:
    span, texto = _exportar(excecao=True)
    eventos = span["events"]
    assert isinstance(eventos, list)
    (evento,) = eventos
    assert evento["attributes"] == {"exception.type": "ValueError"}
    assert span["status"] == {"status_code": "ERROR"}
    assert CPF not in texto
    assert "Traceback" not in texto


def test_span_de_servidor_sem_rota_nao_leva_o_caminho_no_nome() -> None:
    span, texto = _exportar(
        nome=f"GET /qualquer/{CPF}", atributos={"http.request.method": "GET", "url.path": CPF}
    )
    assert span["name"] == "GET"
    assert CPF not in texto


def test_span_de_cliente_mantem_o_nome() -> None:
    span, _ = _exportar(nome="SELECT cybersec", kind=SpanKind.CLIENT)
    assert span["name"] == "SELECT cybersec"


def test_lista_de_permissao_nao_tem_atributo_de_conteudo() -> None:
    sensiveis = {
        "url.path",
        "url.full",
        "url.query",
        "http.url",
        "http.target",
        "client.address",
        "client.port",
        "net.peer.ip",
        "network.peer.address",
        "http.client_ip",
        "user_agent.original",
        "http.user_agent",
        "db.statement",
        "db.query.text",
        "db.user",
        "enduser.id",
        "exception.message",
        "exception.stacktrace",
    }
    assert not ATRIBUTOS_PERMITIDOS & sensiveis
    assert not any(".header." in chave for chave in ATRIBUTOS_PERMITIDOS)


def test_sem_endpoint_a_telemetria_fica_desligada() -> None:
    assert criar_telemetria(get_settings()) is None


def test_com_endpoint_cria_os_providers(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://10.0.0.10:4318/")
    settings = Settings()
    assert settings.otel_exporter_otlp_endpoint == "http://10.0.0.10:4318"
    telemetria = criar_telemetria(settings)
    assert telemetria is not None
    recurso = telemetria.tracer_provider.resource.attributes
    assert recurso["service.name"] == "cybersec-backend"
    assert recurso["deployment.environment.name"] == "test"
    telemetria.tracer_provider.shutdown()
    telemetria.meter_provider.shutdown()


@pytest.mark.parametrize(
    "endpoint",
    [
        "ftp://10.0.0.10:4318",
        "http://usuario:senha@10.0.0.10:4318",
        "http://10.0.0.10:4318/v1/traces",
        "http://10.0.0.10:4318?token=x",
        "10.0.0.10:4318",
    ],
)
def test_endpoint_invalido_impede_a_inicializacao(
    monkeypatch: pytest.MonkeyPatch, endpoint: str
) -> None:
    monkeypatch.setenv("OTEL_EXPORTER_OTLP_ENDPOINT", endpoint)
    with pytest.raises(ValidationError) as erro:
        Settings()
    assert "senha" not in str(erro.value)


@pytest.mark.parametrize("fracao", ["-0.1", "1.5"])
def test_amostragem_fora_de_0_a_1(monkeypatch: pytest.MonkeyPatch, fracao: str) -> None:
    monkeypatch.setenv("OTEL_TRACES_SAMPLER_ARG", fracao)
    with pytest.raises(ValidationError):
        Settings()


def test_banco_exporta_so_operacao_e_duracao() -> None:
    destino = InMemorySpanExporter()
    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(ExportadorFiltrado(destino)))
    engine = create_engine("sqlite://")
    instrumentar_banco(engine, provider)
    with engine.connect() as conn:
        conn.execute(text("SELECT '52998224725'"))  # literal de propósito: não pode sair
        conn.execute(text("SELECT :cpf"), {"cpf": CPF})
        with pytest.raises(OperationalError):
            conn.execute(text("SELECT * FROM inexistente WHERE cpf = '52998224725'"))
    spans = destino.get_finished_spans()
    texto = "".join(span.to_json() for span in spans)
    assert [s.name for s in spans] == ["SELECT postgres"] * 3
    assert spans[0].attributes == {
        "db.system.name": "postgresql",
        "db.namespace": "postgres",
        "db.operation.name": "SELECT",
    }
    assert spans[2].status.status_code is StatusCode.ERROR
    assert spans[2].attributes["error.type"] == "OperationalError"  # type: ignore[index]
    assert CPF not in texto
    assert "inexistente" not in texto


@pytest.mark.parametrize(
    ("comando", "operacao"),
    [("select 1", "SELECT"), ("  INSERT INTO x", "INSERT"), ("VACUUM x", "SQL"), ("", "SQL")],
)
def test_operacao_sql_so_de_lista_fechada(comando: str, operacao: str) -> None:
    assert _operacao(comando) == operacao
