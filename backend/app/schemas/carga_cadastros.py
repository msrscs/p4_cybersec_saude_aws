"""Arquivo de carga dos cadastros de catálogo (ADR-0035).

As referências entre registros usam chaves naturais (nomes únicos e códigos de CID), nunca IDs:
os IDs mudam entre bancos e o cid_hash depende da HMAC_KEY de cada ambiente.
"""

from typing import Literal, Self

from pydantic import Field, model_validator

from app.schemas.cadastro import (
    CodigoCid,
    Descricao,
    DiaSemana,
    Duracao,
    Endereco,
    Hora,
    Prazo,
    Telefone,
    VagasPorHorario,
    _Entrada,
)
from app.schemas.validadores import Nome

Status = Literal["ativo", "inativo"]
LIMITE_ITENS = 10_000
LIMITE_LIGACOES = 1_000

Codigos = list[CodigoCid]
Nomes = list[Nome]


class TipoUnidadeCarga(_Entrada):
    nome: Nome
    descricao: Descricao = ""
    status: Status = "ativo"


class ServicoCarga(_Entrada):
    nome: Nome
    descricao: Descricao = ""
    status: Status = "ativo"
    cids: Codigos = Field(default=[], max_length=LIMITE_LIGACOES)


class UnidadeCarga(_Entrada):
    nome: Nome
    tipo: Nome
    endereco: Endereco
    telefone: Telefone | None = None
    status: Status = "ativo"
    servicos: Nomes = Field(default=[], max_length=LIMITE_LIGACOES)


class TipoOciCarga(_Entrada):
    tipo_oci: Nome
    prazo_diagnostico: Prazo
    status: Status = "ativo"
    cids: Codigos = Field(default=[], max_length=LIMITE_LIGACOES)


class AgendaCarga(_Entrada):
    unidade: Nome
    servico: Nome
    dia_semana: DiaSemana
    hora_inicio: Hora
    hora_fim: Hora
    duracao_minutos: Duracao
    vagas_por_horario: VagasPorHorario
    status: Status = "ativo"

    @model_validator(mode="after")
    def _horarios(self) -> Self:
        if self.hora_inicio >= self.hora_fim:
            raise ValueError("O horário final deve ser depois do inicial.")
        minutos = (self.hora_fim.hour - self.hora_inicio.hour) * 60 + (
            self.hora_fim.minute - self.hora_inicio.minute
        )
        if minutos < self.duracao_minutos:
            raise ValueError("A duração não cabe no intervalo da agenda.")
        return self


def _repetidos(valores: list[str]) -> bool:
    """Os índices únicos do banco comparam lower(nome)."""
    return len({v.lower() for v in valores}) != len(valores)


class CargaCadastros(_Entrada):
    versao: Literal[1]
    tipos_unidade: list[TipoUnidadeCarga] = Field(default=[], max_length=LIMITE_ITENS)
    servicos: list[ServicoCarga] = Field(default=[], max_length=LIMITE_ITENS)
    unidades: list[UnidadeCarga] = Field(default=[], max_length=LIMITE_ITENS)
    tipos_oci: list[TipoOciCarga] = Field(default=[], max_length=LIMITE_ITENS)
    agendas: list[AgendaCarga] = Field(default=[], max_length=LIMITE_ITENS)

    @model_validator(mode="after")
    def _sem_nomes_repetidos(self) -> Self:
        for secao, nomes in (
            ("tipos_unidade", [t.nome for t in self.tipos_unidade]),
            ("servicos", [s.nome for s in self.servicos]),
            ("unidades", [u.nome for u in self.unidades]),
            ("tipos_oci", [t.tipo_oci for t in self.tipos_oci]),
        ):
            if _repetidos(nomes):
                raise ValueError(f"Nome repetido em {secao}.")
        return self
