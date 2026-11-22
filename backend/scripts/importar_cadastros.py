"""Importa os cadastros de catálogo de um JSON de carga (ADR-0035).

Rode depois do importar_cid: os CIDs ligados a serviços e tipos de OCI precisam estar no catálogo.
A partir de backend/ (por padrão, lê db/seeds/cadastros.json):

    uv run --env-file ../.env python -m scripts.importar_cadastros [--arquivo caminho.json]

Pode rodar de novo sem risco: registro que já existe pelo nome é ignorado, sem sobrescrever
correções feitas na tela. Arquivo inválido ou referência inexistente cancela tudo, antes de gravar.
"""

import argparse
import sys
from pathlib import Path

from pydantic import ValidationError

from app.core.config import get_settings
from app.core.database import criar_engine, criar_sessionmaker
from app.schemas.carga_cadastros import CargaCadastros
from app.services import carga_cadastros
from app.services.auditoria import ContextoRequisicao
from app.services.carga_cadastros import CargaInvalida

ARQUIVO_PADRAO = Path(__file__).resolve().parents[2] / "db" / "seeds" / "cadastros.json"


def ler_arquivo(arquivo: Path) -> CargaCadastros:
    """Valida o arquivo inteiro como os cadastros da tela. Cita só a posição do erro."""
    try:
        return CargaCadastros.model_validate_json(arquivo.read_bytes())
    except ValidationError as erro:
        # Erro do arquivo inteiro (nome repetido) não tem posição: usa a mensagem, que é nossa.
        locais = sorted({".".join(map(str, e["loc"])) or e["msg"] for e in erro.errors()})
        sys.exit(f"Arquivo inválido em: {', '.join(locais[:10])}. Nada foi importado.")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Importa os cadastros de catálogo de um JSON.")
    parser.add_argument("--arquivo", type=Path, default=ARQUIVO_PADRAO)
    args = parser.parse_args(argv)
    if not args.arquivo.is_file():
        sys.exit("Arquivo não encontrado.")
    carga = ler_arquivo(args.arquivo)

    settings = get_settings()
    engine = criar_engine(settings)
    try:
        with criar_sessionmaker(engine)() as db, db.begin():
            resultado = carga_cadastros.importar(db, settings, carga, ContextoRequisicao())
    except CargaInvalida as erro:
        sys.exit(f"{erro} Nada foi importado.")
    finally:
        engine.dispose()
    for recurso, contagem in resultado.items():
        print(f"{recurso}: {contagem.criados} importados, {contagem.ignorados} já existiam.")


if __name__ == "__main__":
    main()
