"""Exporta e importa os cadastros de catálogo entre bancos (ADR-0035).

Tipos de unidade, serviços (com CIDs), unidades (com serviços), tipos de OCI (com CIDs) e agendas.
O catálogo de CID vem antes, pelo importar_cid (ADR-0020). As referências usam chaves naturais,
e o cid_hash é recalculado com a HMAC_KEY do destino.

A importação é tudo ou nada (uma transação) e pode rodar de novo: registro que já existe pelo nome
é ignorado, sem sobrescrever correções feitas na tela nem mudar as suas ligações.
"""

from dataclasses import dataclass

from sqlalchemy.orm import Session

from app.core.config import Settings
from app.core.crypto import FinalidadeHash, hash_busca
from app.models import AgendaServico, ServicoSaude, TipoOci, TipoUnidade, UnidadeSaude
from app.repositories import agenda as agenda_repo
from app.repositories import cadastro as cadastro_repo
from app.repositories import carga_cadastros as carga_repo
from app.schemas.carga_cadastros import (
    AgendaCarga,
    CargaCadastros,
    ServicoCarga,
    TipoOciCarga,
    TipoUnidadeCarga,
    UnidadeCarga,
)
from app.services import auditoria
from app.services.auditoria import ContextoRequisicao, Evento
from app.services.cadastro import AGENDAS, SERVICOS, TIPOS_OCI, TIPOS_UNIDADE, UNIDADES


class CargaInvalida(Exception):
    """Referência que não existe no destino. A mensagem cita só nomes e códigos do catálogo."""


@dataclass
class Contagem:
    criados: int = 0
    ignorados: int = 0


def exportar(db: Session) -> CargaCadastros:
    agendas = sorted(
        carga_repo.agendas(db),
        key=lambda a: (a.unidade.nome.lower(), a.servico.nome.lower(), a.dia_semana, a.hora_inicio),
    )
    return CargaCadastros(
        versao=1,
        tipos_unidade=[
            TipoUnidadeCarga(nome=t.nome, descricao=t.descricao, status=t.status)
            for t in carga_repo.tipos_unidade(db)
        ],
        servicos=[
            ServicoCarga(
                nome=s.nome,
                descricao=s.descricao,
                status=s.status,
                cids=sorted(c.cid for c in s.cids),
            )
            for s in carga_repo.servicos(db)
        ],
        unidades=[
            UnidadeCarga(
                nome=u.nome,
                tipo=u.tipo.nome,
                endereco=u.endereco,
                telefone=u.telefone,
                status=u.status,
                servicos=sorted((s.nome for s in u.servicos), key=str.lower),
            )
            for u in carga_repo.unidades(db)
        ],
        tipos_oci=[
            TipoOciCarga(
                tipo_oci=t.tipo_oci,
                prazo_diagnostico=t.prazo_diagnostico,
                status=t.status,
                cids=sorted(c.cid for c in t.cids),
            )
            for t in carga_repo.tipos_oci(db)
        ],
        agendas=[
            AgendaCarga(
                unidade=a.unidade.nome,
                servico=a.servico.nome,
                dia_semana=a.dia_semana,
                hora_inicio=a.hora_inicio,
                hora_fim=a.hora_fim,
                duracao_minutos=a.duracao_minutos,
                vagas_por_horario=a.vagas_por_horario,
                status=a.status,
            )
            for a in agendas
        ],
    )


def importar(
    db: Session, settings: Settings, carga: CargaCadastros, ctx: ContextoRequisicao
) -> dict[str, Contagem]:
    hashes = _hashes_dos_cids(db, settings, carga)
    resultado = {
        TIPOS_UNIDADE.recurso: _importar_tipos(db, carga.tipos_unidade),
        SERVICOS.recurso: _importar_servicos(db, carga.servicos, hashes),
        UNIDADES.recurso: _importar_unidades(db, carga.unidades),
        TIPOS_OCI.recurso: _importar_tipos_oci(db, carga.tipos_oci, hashes),
        AGENDAS.recurso: _importar_agendas(db, carga.agendas),
    }
    for recurso, contagem in resultado.items():
        auditoria.registrar(
            db,
            Evento.CATALOG_IMPORTED,
            ctx,
            resumo={
                "recurso": recurso,
                "criados": contagem.criados,
                "ignorados": contagem.ignorados,
            },
        )
    return resultado


def _hashes_dos_cids(db: Session, settings: Settings, carga: CargaCadastros) -> dict[str, bytes]:
    codigos = {c for s in carga.servicos for c in s.cids} | {
        c for t in carga.tipos_oci for c in t.cids
    }
    hashes = {c: hash_busca(settings.chave_hmac, FinalidadeHash.CID, c) for c in codigos}
    existentes = carga_repo.cids_existentes(db, hashes.values())
    faltando = sorted(c for c, h in hashes.items() if h not in existentes)
    if faltando:
        raise CargaInvalida(
            f"CIDs fora do catálogo (rode o importar_cid antes): {', '.join(faltando[:20])}."
        )
    return hashes


def _importar_tipos(db: Session, itens: list[TipoUnidadeCarga]) -> Contagem:
    contagem = Contagem()
    existentes = carga_repo.ids_por_nome(db, TipoUnidade.nome, TipoUnidade.id_tipo_unidade)
    for item in itens:
        if item.nome.lower() in existentes:
            contagem.ignorados += 1
            continue
        cadastro_repo.inserir(db, TipoUnidade(**item.model_dump()))
        contagem.criados += 1
    return contagem


def _importar_servicos(
    db: Session, itens: list[ServicoCarga], hashes: dict[str, bytes]
) -> Contagem:
    contagem = Contagem()
    existentes = carga_repo.ids_por_nome(db, ServicoSaude.nome, ServicoSaude.id_servico)
    for item in itens:
        if item.nome.lower() in existentes:
            contagem.ignorados += 1
            continue
        registro = ServicoSaude(**item.model_dump(exclude={"cids"}))
        cadastro_repo.inserir(db, registro)
        cadastro_repo.incluir_cids_no_servico(
            db, registro.id_servico, {hashes[c] for c in item.cids}
        )
        contagem.criados += 1
    return contagem


def _importar_unidades(db: Session, itens: list[UnidadeCarga]) -> Contagem:
    contagem = Contagem()
    tipos = carga_repo.ids_por_nome(db, TipoUnidade.nome, TipoUnidade.id_tipo_unidade)
    servicos = carga_repo.ids_por_nome(db, ServicoSaude.nome, ServicoSaude.id_servico)
    existentes = carga_repo.ids_por_nome(db, UnidadeSaude.nome, UnidadeSaude.id_unidade)
    for item in itens:
        if item.nome.lower() in existentes:
            contagem.ignorados += 1
            continue
        id_tipo = _buscar(tipos, item.tipo, f"Tipo de unidade inexistente: {item.tipo}.")
        ids_servicos = {
            _buscar(servicos, s, f"Serviço inexistente na unidade {item.nome}: {s}.")
            for s in item.servicos
        }
        registro = UnidadeSaude(
            **item.model_dump(exclude={"tipo", "servicos"}), id_tipo_unidade=id_tipo
        )
        cadastro_repo.inserir(db, registro)
        cadastro_repo.incluir_servicos(db, registro.id_unidade, ids_servicos)
        contagem.criados += 1
    return contagem


def _importar_tipos_oci(
    db: Session, itens: list[TipoOciCarga], hashes: dict[str, bytes]
) -> Contagem:
    contagem = Contagem()
    existentes = carga_repo.ids_por_nome(db, TipoOci.tipo_oci, TipoOci.id_tipo_oci)
    for item in itens:
        if item.tipo_oci.lower() in existentes:
            contagem.ignorados += 1
            continue
        registro = TipoOci(**item.model_dump(exclude={"cids"}))
        cadastro_repo.inserir(db, registro)
        cadastro_repo.incluir_cids(db, registro.id_tipo_oci, {hashes[c] for c in item.cids})
        contagem.criados += 1
    return contagem


def _importar_agendas(db: Session, itens: list[AgendaCarga]) -> Contagem:
    """Mesmas regras da tela: serviço oferecido na unidade e sem sobreposição entre ativas."""
    contagem = Contagem()
    unidades = carga_repo.ids_por_nome(db, UnidadeSaude.nome, UnidadeSaude.id_unidade)
    servicos = carga_repo.ids_por_nome(db, ServicoSaude.nome, ServicoSaude.id_servico)
    existentes = carga_repo.chaves_de_agenda(db)
    for item in itens:
        rotulo = f"{item.unidade} / {item.servico}, dia {item.dia_semana} às {item.hora_inicio}"
        id_unidade = _buscar(unidades, item.unidade, f"Unidade inexistente na agenda {rotulo}.")
        id_servico = _buscar(servicos, item.servico, f"Serviço inexistente na agenda {rotulo}.")
        chave = (id_unidade, id_servico, item.dia_semana, item.hora_inicio)
        if chave in existentes:
            contagem.ignorados += 1
            continue
        if not cadastro_repo.servico_na_unidade(db, id_unidade, id_servico):
            raise CargaInvalida(f"Agenda {rotulo}: a unidade não oferece o serviço.")
        if item.status == "ativo" and _sobrepoe(db, id_unidade, id_servico, item):
            raise CargaInvalida(f"Agenda {rotulo}: sobrepõe outra agenda ativa.")
        dados = item.model_dump(exclude={"unidade", "servico"})
        cadastro_repo.inserir(
            db, AgendaServico(**dados, id_unidade=id_unidade, id_servico=id_servico)
        )
        existentes.add(chave)
        contagem.criados += 1
    return contagem


def _sobrepoe(db: Session, id_unidade: int, id_servico: int, item: AgendaCarga) -> bool:
    return any(
        item.hora_inicio < outra.hora_fim and outra.hora_inicio < item.hora_fim
        for outra in agenda_repo.outras_agendas_no_dia(
            db, id_unidade, id_servico, item.dia_semana, None
        )
    )


def _buscar(ids: dict[str, int], nome: str, erro: str) -> int:
    try:
        return ids[nome.lower()]
    except KeyError:
        raise CargaInvalida(erro) from None
