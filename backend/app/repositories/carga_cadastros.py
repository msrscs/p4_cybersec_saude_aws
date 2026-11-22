"""Consultas da carga de cadastros por chave natural (ADR-0035)."""

from collections.abc import Iterable
from datetime import time

from sqlalchemy import func, select
from sqlalchemy.orm import InstrumentedAttribute, Session

from app.models import AgendaServico, Cid, ServicoSaude, TipoOci, TipoUnidade, UnidadeSaude

type ChaveAgenda = tuple[int, int, int, time]


def ids_por_nome(
    db: Session, nome: InstrumentedAttribute[str], chave: InstrumentedAttribute[int]
) -> dict[str, int]:
    """lower(nome) -> id, como nos índices únicos das tabelas."""
    return {n: i for n, i in db.execute(select(func.lower(nome), chave))}


def cids_existentes(db: Session, hashes: Iterable[bytes]) -> set[bytes]:
    return set(db.scalars(select(Cid.cid_hash).where(Cid.cid_hash.in_(list(hashes)))))


def chaves_de_agenda(db: Session) -> set[ChaveAgenda]:
    consulta = select(
        AgendaServico.id_unidade,
        AgendaServico.id_servico,
        AgendaServico.dia_semana,
        AgendaServico.hora_inicio,
    )
    return {(u, s, d, h) for u, s, d, h in db.execute(consulta)}


def tipos_unidade(db: Session) -> list[TipoUnidade]:
    return list(db.scalars(select(TipoUnidade).order_by(func.lower(TipoUnidade.nome))))


def servicos(db: Session) -> list[ServicoSaude]:
    return list(db.scalars(select(ServicoSaude).order_by(func.lower(ServicoSaude.nome))))


def unidades(db: Session) -> list[UnidadeSaude]:
    return list(db.scalars(select(UnidadeSaude).order_by(func.lower(UnidadeSaude.nome))))


def tipos_oci(db: Session) -> list[TipoOci]:
    return list(db.scalars(select(TipoOci).order_by(func.lower(TipoOci.tipo_oci))))


def agendas(db: Session) -> list[AgendaServico]:
    return list(db.scalars(select(AgendaServico).order_by(AgendaServico.id_agenda)))
