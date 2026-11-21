#!/usr/bin/env bash
# Gera as chaves da aplicação com o próprio scripts.gerar_chaves (ADR-0004) e grava nos segredos
# criados pelo Terraform. Só preenche segredo vazio: a HMAC_KEY e a LOG_CHECKPOINT_KEY nunca
# podem ser trocadas depois que houver dados (ADR-0010), e a KEK só muda por rotação.
#
# Uso (na raiz do repositório, com credenciais da AWS):
#   infra/scripts/popular_chaves.sh
#
# Nada é exibido nem passa pela linha de comando de outro processo: os valores vão em arquivos
# temporários com permissão 600, apagados ao sair.
set -euo pipefail
umask 077

RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
REGIAO="${AWS_REGION:-$(terraform -chdir="$RAIZ/infra" output -raw regiao)}"
CHAVES="cybersec/chaves-aplicacao"
CHECKPOINT="cybersec/log-checkpoint-key"

tem_valor() {
  aws secretsmanager get-secret-value --region "$REGIAO" --secret-id "$1" \
    --query VersionId --output text >/dev/null 2>&1
}

if tem_valor "$CHAVES" || tem_valor "$CHECKPOINT"; then
  echo "Os segredos já têm valor; nada foi alterado (para rotacionar a KEK, veja o README)." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

(cd "$RAIZ/backend" && uv run python -m scripts.gerar_chaves --env "$TMP/chaves.env" >/dev/null)

python3 - "$TMP" <<'PY'
import json
import sys
from pathlib import Path

tmp = Path(sys.argv[1])
valores = dict(
    linha.split("=", 1) for linha in (tmp / "chaves.env").read_text().splitlines() if "=" in linha
)
app = {nome: valores[nome] for nome in ("KEK_KEYRING", "KEK_ATIVA", "HMAC_KEY")}
(tmp / "chaves.json").write_text(json.dumps(app))
(tmp / "checkpoint.txt").write_text(valores["LOG_CHECKPOINT_KEY"])
PY

aws secretsmanager put-secret-value --region "$REGIAO" --secret-id "$CHAVES" \
  --secret-string "file://$TMP/chaves.json" >/dev/null
aws secretsmanager put-secret-value --region "$REGIAO" --secret-id "$CHECKPOINT" \
  --secret-string "file://$TMP/checkpoint.txt" >/dev/null
echo "Chaves geradas e gravadas em $CHAVES e $CHECKPOINT."
