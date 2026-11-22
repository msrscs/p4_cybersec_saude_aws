"""Exporta os cadastros de catálogo para um JSON de carga (ADR-0035).

Lê tipos de unidade, serviços, unidades, tipos de OCI e agendas do banco configurado no ambiente
(role da aplicação, só SELECT) e grava o arquivo usado pelo importar_cadastros. A partir de
backend/:

    uv run --env-file ../.env python -m scripts.exportar_cadastros [--arquivo caminho.json]

São dados públicos de catálogo: o arquivo não tem paciente, usuário nem hash.
"""

import argparse
from pathlib import Path

from app.core.config import get_settings
from app.core.database import criar_engine, criar_sessionmaker
from app.services import carga_cadastros

ARQUIVO_PADRAO = Path(__file__).resolve().parents[2] / "db" / "seeds" / "cadastros.json"


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Exporta os cadastros de catálogo para JSON.")
    parser.add_argument("--arquivo", type=Path, default=ARQUIVO_PADRAO)
    args = parser.parse_args(argv)

    settings = get_settings()
    engine = criar_engine(settings)
    try:
        with criar_sessionmaker(engine)() as db:
            carga = carga_cadastros.exportar(db)
    finally:
        engine.dispose()
    args.arquivo.write_text(carga.model_dump_json(indent=2) + "\n", encoding="utf-8")
    print(
        f"Exportados: {len(carga.tipos_unidade)} tipos de unidade, {len(carga.servicos)} serviços,"
        f" {len(carga.unidades)} unidades, {len(carga.tipos_oci)} tipos de OCI,"
        f" {len(carga.agendas)} agendas."
    )


if __name__ == "__main__":
    main()
