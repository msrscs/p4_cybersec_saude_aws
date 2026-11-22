"""ADR-0035: exportação e importação dos cadastros de catálogo entre bancos."""

import json
import secrets
from pathlib import Path
from typing import Any

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from app.core.config import Settings
from app.core.crypto import FinalidadeHash, hash_busca
from app.models import AgendaServico, Log, ServicoSaude, TipoOci, TipoUnidade, UnidadeSaude
from app.services import cadastro
from app.services.auditoria import ContextoRequisicao
from scripts import exportar_cadastros, importar_cadastros

Fabrica = sessionmaker[Session]


@pytest.fixture(autouse=True)
def _settings(monkeypatch: pytest.MonkeyPatch, settings_integracao: Settings) -> None:
    for modulo in (exportar_cadastros, importar_cadastros):
        monkeypatch.setattr(modulo, "get_settings", lambda: settings_integracao)


@pytest.fixture
def cid(fabrica_sessao: Fabrica, settings_integracao: Settings) -> str:
    """Código novo no catálogo, como o importar_cid deixaria."""
    codigo = f"Z{secrets.randbelow(100):02d}.{secrets.token_hex(1).upper()}"
    with fabrica_sessao() as db, db.begin():
        cadastro.importar_cids(
            db, settings_integracao, [(codigo, "CID de teste")], ContextoRequisicao()
        )
    return codigo


def _carga(cid: str) -> dict[str, Any]:
    s = secrets.token_hex(4)
    return {
        "versao": 1,
        "tipos_unidade": [{"nome": f"Tipo {s}", "descricao": "Policlínica"}],
        "servicos": [
            {"nome": f"Mamografia {s}", "cids": [cid]},
            {"nome": f"Ultrassom {s}", "status": "inativo"},
        ],
        "unidades": [
            {
                "nome": f"Unidade {s}",
                "tipo": f"TIPO {s}",  # chave natural, sem diferenciar maiúsculas
                "endereco": "Rua A, 1",
                "telefone": "8133334444",
                "servicos": [f"Mamografia {s}"],
            }
        ],
        "tipos_oci": [{"tipo_oci": f"OCI {s}", "prazo_diagnostico": 60, "cids": [cid]}],
        "agendas": [
            {
                "unidade": f"Unidade {s}",
                "servico": f"Mamografia {s}",
                "dia_semana": 0,
                "hora_inicio": "08:00",
                "hora_fim": "12:00",
                "duracao_minutos": 30,
                "vagas_por_horario": 2,
            }
        ],
    }


def _arquivo(pasta: Path, carga: dict[str, Any]) -> Path:
    arquivo = pasta / "cadastros.json"
    arquivo.write_text(json.dumps(carga), encoding="utf-8")
    return arquivo


def _contar(db: Session, modelo: type[Any], coluna: Any, valor: object) -> int:
    return db.scalar(select(func.count()).select_from(modelo).where(coluna == valor)) or 0


def test_importa_com_ligacoes_hash_do_destino_e_auditoria(
    tmp_path: Path,
    fabrica_sessao: Fabrica,
    settings_integracao: Settings,
    cid: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    carga = _carga(cid)
    importar_cadastros.main(["--arquivo", str(_arquivo(tmp_path, carga))])
    saida = capsys.readouterr().out
    assert "tipo_unidade: 1 importados" in saida and "agenda_servico: 1 importados" in saida

    cid_hash = hash_busca(settings_integracao.chave_hmac, FinalidadeHash.CID, cid)
    with fabrica_sessao() as db:
        unidade = db.scalars(
            select(UnidadeSaude).where(UnidadeSaude.nome == carga["unidades"][0]["nome"])
        ).one()
        servico = db.scalars(
            select(ServicoSaude).where(ServicoSaude.nome == carga["servicos"][0]["nome"])
        ).one()
        inativo = db.scalars(
            select(ServicoSaude).where(ServicoSaude.nome == carga["servicos"][1]["nome"])
        ).one()
        tipo_oci = db.scalars(
            select(TipoOci).where(TipoOci.tipo_oci == carga["tipos_oci"][0]["tipo_oci"])
        ).one()
        agenda = db.scalars(
            select(AgendaServico).where(AgendaServico.id_unidade == unidade.id_unidade)
        ).one()
        eventos = db.scalars(
            select(Log).where(Log.acao == "catalog_imported").order_by(Log.seq_cadeia.desc())
        ).all()[:5]

        assert unidade.tipo.nome == carga["tipos_unidade"][0]["nome"]
        assert [s.id_servico for s in unidade.servicos] == [servico.id_servico]
        assert [c.cid_hash for c in servico.cids] == [cid_hash]
        assert [c.cid_hash for c in tipo_oci.cids] == [cid_hash]
        assert inativo.status == "inativo"
        assert (agenda.id_servico, agenda.vagas_por_horario) == (servico.id_servico, 2)
    assert {e.resumo_acessado["recurso"] for e in eventos} == {
        "tipo_unidade",
        "servico_saude",
        "unidade_saude",
        "tipo_oci",
        "agenda_servico",
    }


def test_rodar_de_novo_nao_duplica_nem_sobrescreve(
    tmp_path: Path, fabrica_sessao: Fabrica, cid: str, capsys: pytest.CaptureFixture[str]
) -> None:
    carga = _carga(cid)
    arquivo = _arquivo(tmp_path, carga)
    importar_cadastros.main(["--arquivo", str(arquivo)])
    nome = carga["tipos_unidade"][0]["nome"]
    with fabrica_sessao() as db, db.begin():
        db.scalars(select(TipoUnidade).where(TipoUnidade.nome == nome)).one().descricao = "Tela"
    capsys.readouterr()

    importar_cadastros.main(["--arquivo", str(arquivo)])
    saida = capsys.readouterr().out
    assert "0 importados" in saida and " 1 importados" not in saida
    with fabrica_sessao() as db:
        assert db.scalars(select(TipoUnidade).where(TipoUnidade.nome == nome)).one().descricao == (
            "Tela"
        )
        assert _contar(db, AgendaServico, AgendaServico.vagas_por_horario, 2) >= 1


@pytest.mark.parametrize(
    ("alterar", "mensagem"),
    [
        (lambda c: c["servicos"][0]["cids"].append("Y99.9"), "CIDs fora do catálogo"),
        (lambda c: c["unidades"][0].update(tipo="Tipo que não existe"), "Tipo de unidade"),
        (lambda c: c["agendas"][0].update(servico=c["servicos"][1]["nome"]), "não oferece"),
    ],
)
def test_referencia_invalida_cancela_tudo(
    tmp_path: Path, fabrica_sessao: Fabrica, cid: str, alterar: Any, mensagem: str
) -> None:
    carga = _carga(cid)
    alterar(carga)
    with pytest.raises(SystemExit, match=mensagem):
        importar_cadastros.main(["--arquivo", str(_arquivo(tmp_path, carga))])
    with fabrica_sessao() as db:
        nome = carga["tipos_unidade"][0]["nome"]
        assert _contar(db, TipoUnidade, TipoUnidade.nome, nome) == 0


def test_agenda_sobreposta_e_recusada(tmp_path: Path, cid: str) -> None:
    carga = _carga(cid)
    carga["agendas"].append({**carga["agendas"][0], "hora_inicio": "11:00", "hora_fim": "13:00"})
    with pytest.raises(SystemExit, match="sobrepõe"):
        importar_cadastros.main(["--arquivo", str(_arquivo(tmp_path, carga))])


@pytest.mark.parametrize(
    ("alterar", "local"),
    [
        (lambda c: c["servicos"].append({"nome": c["servicos"][0]["nome"].upper()}), "servicos"),
        (lambda c: c["agendas"][0].update(duracao_minutos=300), "agendas.0"),
        (lambda c: c["unidades"][0].update(telefone="123"), "unidades.0.telefone"),
        (lambda c: c.update(versao=2), "versao"),
        (lambda c: c["tipos_oci"][0].update(id_tipo_oci=1), "tipos_oci.0.id_tipo_oci"),
    ],
)
def test_arquivo_invalido_nao_importa_nada(
    tmp_path: Path, cid: str, alterar: Any, local: str
) -> None:
    carga = _carga(cid)
    alterar(carga)
    with pytest.raises(SystemExit, match=local):
        importar_cadastros.main(["--arquivo", str(_arquivo(tmp_path, carga))])


def test_exportacao_usa_chaves_naturais_e_volta_igual(
    tmp_path: Path, cid: str, capsys: pytest.CaptureFixture[str]
) -> None:
    carga = _carga(cid)
    importar_cadastros.main(["--arquivo", str(_arquivo(tmp_path, carga))])
    saida = tmp_path / "exportado.json"
    exportar_cadastros.main(["--arquivo", str(saida)])
    assert "Exportados:" in capsys.readouterr().out

    texto = saida.read_text(encoding="utf-8")
    exportado = json.loads(texto)
    assert "hash" not in texto and "id_" not in texto
    servico = next(s for s in exportado["servicos"] if s["nome"] == carga["servicos"][0]["nome"])
    unidade = next(u for u in exportado["unidades"] if u["nome"] == carga["unidades"][0]["nome"])
    agenda = next(a for a in exportado["agendas"] if a["unidade"] == unidade["nome"])
    assert servico["cids"] == [cid]
    assert unidade["tipo"] == carga["tipos_unidade"][0]["nome"]
    assert unidade["servicos"] == [servico["nome"]]
    assert agenda["hora_inicio"] == "08:00:00" and agenda["status"] == "ativo"

    # O próprio arquivo exportado é uma carga válida: importá-lo de novo não muda nada.
    importar_cadastros.main(["--arquivo", str(saida)])
    assert " 1 importados" not in capsys.readouterr().out
