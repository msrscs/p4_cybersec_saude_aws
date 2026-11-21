"""T12 / THREAT_MODEL I8: o fluxo real (login, MFA, paciente, erros) não vaza dado na telemetria.

Os spans e as métricas exportados são serializados por inteiro e procurados por cada valor
sensível usado nas requisições: CPF, senha, e-mail, nome, segredo e código TOTP, cookies, token
CSRF, id do paciente, IP do cliente e texto SQL.
"""

from collections.abc import Iterator
from datetime import UTC, datetime
from urllib.parse import parse_qs, urlparse

import pyotp
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.metrics.export import InMemoryMetricReader
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from sqlalchemy.orm import Session, sessionmaker

from app.core import totp
from app.core.config import Settings
from app.core.cpf import formatar_cpf
from app.core.telemetria import Telemetria, criar_telemetria
from app.main import create_app
from app.services import autorizacao
from app.services import usuario as usuario_service
from app.services.auditoria import ContextoRequisicao
from app.services.usuario import NovoUsuario

from .conftest import com_csrf, gerar_cpf

SENHA = "Saúde#Recife2026"
IP_CLIENTE = "203.0.113.77"
TRACE_ID = "4bf92f3577b34da6a3ce929d0e0e4736"


class Coletor:
    def __init__(self, settings: Settings) -> None:
        self.spans = InMemorySpanExporter()
        self.metricas = InMemoryMetricReader()
        telemetria = criar_telemetria(settings, self.spans, self.metricas)
        assert telemetria is not None
        self.telemetria: Telemetria = telemetria

    def exportado(self) -> tuple[list[dict[str, object]], str]:
        self.telemetria.tracer_provider.force_flush()
        spans = self.spans.get_finished_spans()
        metricas = self.metricas.get_metrics_data()
        assert metricas is not None
        texto = "\n".join(span.to_json() for span in spans) + metricas.to_json()
        return [
            {"name": s.name, "kind": s.kind.name, **dict(s.attributes or {})} for s in spans
        ], texto


@pytest.fixture
def coletor(settings_integracao: Settings) -> Iterator[tuple[FastAPI, Coletor]]:
    coletor = Coletor(settings_integracao)
    app = create_app(settings_integracao, coletor.telemetria)
    yield app, coletor
    FastAPIInstrumentor.uninstrument_app(app)
    coletor.telemetria.tracer_provider.shutdown()
    coletor.telemetria.meter_provider.shutdown()
    app.state.engine.dispose()


def test_fluxo_completo_sem_dado_sensivel_na_telemetria(
    coletor: tuple[FastAPI, Coletor],
    fabrica_sessao: sessionmaker[Session],
    settings_integracao: Settings,
) -> None:
    app, col = coletor
    cpf, cpf_paciente = gerar_cpf(), gerar_cpf()
    email = f"tele{cpf}@recife.pe.gov.br"
    with fabrica_sessao() as db, db.begin():
        usuario_service.cadastrar(
            db,
            settings_integracao,
            NovoUsuario(cpf=cpf, nome="Telma", email=email, senha=SENHA),
            ContextoRequisicao(),
        )
        autorizacao.alterar_grupo(
            db,
            settings_integracao,
            cpf=cpf,
            grupo="Administrador",
            remover=False,
            ctx=ContextoRequisicao(),
        )

    with TestClient(app, base_url="https://testserver", client=(IP_CLIENTE, 50000)) as api:
        assert api.post("/auth/login", json={"cpf": cpf, "senha": SENHA}).status_code == 200
        uri = api.post("/auth/mfa/cadastro").json()["otpauth_uri"]
        segredo = parse_qs(urlparse(uri).query)["secret"][0]
        codigo = pyotp.TOTP(segredo).at(totp.passo(datetime.now(UTC)) * 30)
        ativacao = api.post("/auth/mfa/ativar", json={"codigo": codigo})
        assert ativacao.status_code == 200
        codigos_recuperacao = [str(c) for c in ativacao.json().get("codigos_recuperacao", [])]
        com_csrf(api)
        csrf = api.headers["X-CSRF-Token"]
        cookies = [str(v) for v in api.cookies.values()]

        novo = {
            "cpf": formatar_cpf(cpf_paciente),
            "nome": "Josefa Telemetria",
            "data_nascimento": "1980-05-17",
            "email": "josefa.telemetria@exemplo.com.br",
        }
        criado = api.post("/pacientes", json=novo)
        assert criado.status_code == 201, criado.text
        id_paciente = criado.json()["id"]
        assert api.get(f"/pacientes/{id_paciente}?cpf={cpf_paciente}").status_code == 200
        assert api.post("/pacientes/busca", json={"cpf": cpf_paciente}).status_code == 200
        # Rota inexistente e entrada inválida: caminho e valor recebidos não podem aparecer.
        assert api.get(f"/inexistente/{cpf_paciente}").status_code == 404
        invalido = api.post("/pacientes", json={**novo, "email": f"{cpf_paciente}@@x"})
        assert invalido.status_code == 422
        # Contexto de trace vindo do frontend é aceito (W3C traceparent).
        api.get("/auth/sessao", headers={"traceparent": f"00-{TRACE_ID}-00f067aa0ba902b7-01"})

    spans, texto = col.exportado()

    sensiveis = {
        "CPF do usuário": cpf,
        "CPF do paciente": cpf_paciente,
        "CPF formatado": formatar_cpf(cpf_paciente),
        "senha": SENHA,
        "e-mail": email,
        "e-mail do paciente": "josefa.telemetria",
        "nome do paciente": "Josefa",
        "segredo TOTP": segredo,
        "código TOTP": codigo,
        "token CSRF": csrf,
        "id do paciente": id_paciente,
        "IP do cliente": IP_CLIENTE,
        "texto SQL": " FROM ",
        "query string": "?cpf=",
        **{f"cookie {i}": valor for i, valor in enumerate(cookies)},
        **{f"recuperação {i}": valor for i, valor in enumerate(codigos_recuperacao)},
    }
    vazados = [nome for nome, valor in sensiveis.items() if valor and valor in texto]
    assert vazados == []

    # E a telemetria continua útil: rota como modelo, banco instrumentado, trace propagado.
    rotas = {s.get("http.route") for s in spans if s["kind"] == "SERVER"}
    assert {"/auth/login", "/pacientes/{id_paciente}", "/pacientes/busca"} <= rotas
    banco = {s["name"] for s in spans if s.get("db.system.name") == "postgresql"}
    assert f"SELECT {settings_integracao.postgres_db}" in banco
    assert f"INSERT {settings_integracao.postgres_db}" in banco
    assert TRACE_ID in texto
    assert "http.server" in texto  # métricas de duração por rota
