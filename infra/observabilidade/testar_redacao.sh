#!/usr/bin/env bash
# Teste de ponta a ponta da redação do Collector (T14, ADR-0037), só com Docker, sem AWS.
#
#   infra/observabilidade/testar_redacao.sh
#
# 1. Sobe o Collector com o collector.yaml real (mais teste/collector-teste.yaml, que só troca os
#    destinos por um arquivo) e envia, por OTLP/HTTP, um span, uma métrica e um log cheios de dado
#    sensível: em atributos proibidos, em atributos permitidos, no nome do span, num evento de
#    exceção e no corpo do log.
# 2. Falha se qualquer valor sensível aparecer na saída, ou se a telemetria útil (rota, status,
#    nome do serviço) sumir.
# 3. Valida as configs do Prometheus e do Loki com as ferramentas das próprias imagens, e sobe
#    Tempo, Loki, Prometheus e Grafana pelo compose.yml para conferir que iniciam.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
NOME="otelcol-teste-$$"
PROJETO="obs-teste-$$"
PORTA="${PORTA_TESTE:-14318}"
imagem() { sed -n "s/^ *image: \(.*$1.*\)$/\1/p" "$DIR/compose.yml" | head -1; }

limpar() {
  docker rm -f "$NOME" >/dev/null 2>&1 || true
  docker compose -p "$PROJETO" -f "$DIR/compose.yml" --project-directory "$TMP/pilha" \
    down -v >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap limpar EXIT
falha() { echo "FALHOU: $*" >&2; exit 1; }

# --- 1. Redação -----------------------------------------------------------------------------
mkdir -p "$TMP/saida" && chmod 777 "$TMP/saida"
docker run -d --name "$NOME" -p "127.0.0.1:$PORTA:4318" \
  -v "$DIR/collector.yaml:/etc/otelcol/collector.yaml:ro" \
  -v "$DIR/teste/collector-teste.yaml:/etc/otelcol/teste.yaml:ro" \
  -v "$TMP/saida:/saida" \
  -e OTLP_ESCUTA=0.0.0.0:4318 -e AWS_REGION=us-east-1 -e GRUPOS_DE_LOG=/nenhum/ \
  -e DESTINO_TEMPO=127.0.0.1:4317 -e DESTINO_LOKI=http://127.0.0.1:3100/otlp \
  -e DESTINO_PROMETHEUS=http://127.0.0.1:9090/api/v1/otlp \
  "$(imagem opentelemetry-collector)" \
  --config=/etc/otelcol/collector.yaml --config=/etc/otelcol/teste.yaml >/dev/null

for _ in $(seq 1 30); do
  curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' -d '{}' \
    "http://127.0.0.1:$PORTA/v1/traces" 2>/dev/null && break
  sleep 1
done

enviar() {
  curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
    --data-binary "@$DIR/teste/$1.json" "http://127.0.0.1:$PORTA/v1/$1" \
    || falha "o Collector recusou $1"
}
enviar traces
enviar metrics
enviar logs
sleep 7 # batch de 5 s
docker stop -t 10 "$NOME" >/dev/null
SAIDA="$TMP/saida/telemetria.json"
[[ -s "$SAIDA" ]] || falha "nada foi exportado; logs do Collector: $(docker logs "$NOME" 2>&1 | tail -5)"

SENSIVEIS=(
  "123.456.789-09" "12345678909" "fulana@exemplo.com" "abc.def.ghi" "eyJhbGciOiJIUzI1NiJ9"
  "482913" "200.150.10.20" "hunter2" "sessao-secreta" "csrf-secreto" "maquina-secreta"
  "python -m app" "Maria da Silva"
)
vazou=0
for valor in "${SENSIVEIS[@]}"; do
  if grep -qF -- "$valor" "$SAIDA"; then
    echo "VAZOU: $valor em: $(python3 -c '
import sys; t=open(sys.argv[1]).read(); v=sys.argv[2]
print(" | ".join(t[max(0,i-70):i+len(v)+5] for i in [t.find(v)]))' "$SAIDA" "$valor")" >&2
    vazou=1
  fi
done
[[ $vazou -eq 0 ]] || falha "valores sensíveis na saída (acima)"
for util in '/pacientes/{id_paciente}' '"cybersec-teste"' '"http.response.status_code"' \
  'cybersec_teste_requisicoes' 'Login recusado'; do
  grep -qF -- "$util" "$SAIDA" || falha "telemetria útil sumiu: $util"
done
echo "OK: redação de traces, métricas e logs (${#SENSIVEIS[@]} valores sensíveis barrados)"

# --- 2. Configs dos outros serviços ---------------------------------------------------------
docker run --rm --entrypoint promtool -v "$DIR/prometheus.yml:/p.yml:ro" \
  "$(imagem prometheus)" check config /p.yml >/dev/null || falha "prometheus.yml"
docker run --rm -v "$DIR/loki.yaml:/l.yaml:ro" "$(imagem loki)" \
  -config.file=/l.yaml -verify-config >/dev/null 2>&1 || falha "loki.yaml"
echo "OK: prometheus.yml e loki.yaml válidos"

# --- 3. Pilha sem o Collector (ele usa a rede do host, que só existe na EC2) ------------------
mkdir -p "$TMP/pilha/segredos"
cp -r "$DIR"/{compose.yml,tempo.yaml,loki.yaml,prometheus.yml,collector.yaml,grafana} "$TMP/pilha/"
printf 'OTLP_ESCUTA=127.0.0.1:4318\nAWS_REGION=us-east-1\nGRUPOS_DE_LOG=/nenhum/\n' >"$TMP/pilha/.env"
head -c 24 /dev/urandom | base64 >"$TMP/pilha/segredos/grafana_admin"
# Portas locais livres não importam: só a rede interna é usada aqui.
sed -i 's/"127.0.0.1:\([0-9]*\):/"127.0.0.1::/' "$TMP/pilha/compose.yml"
docker compose -p "$PROJETO" -f "$TMP/pilha/compose.yml" --project-directory "$TMP/pilha" \
  up -d --quiet-pull tempo loki prometheus grafana >/dev/null 2>&1 || falha "compose up"

pronto() {
  docker compose -p "$PROJETO" -f "$TMP/pilha/compose.yml" --project-directory "$TMP/pilha" \
    exec -T grafana wget -qO- "$1" >/dev/null 2>&1
}
for alvo in http://localhost:3000/api/health http://prometheus:9090/-/ready \
  http://loki:3100/ready http://tempo:3200/ready; do
  for _ in $(seq 1 60); do pronto "$alvo" && continue 2; sleep 2; done
  docker compose -p "$PROJETO" -f "$TMP/pilha/compose.yml" --project-directory "$TMP/pilha" \
    logs --tail 20 >&2
  falha "serviço não ficou pronto: $alvo"
done
echo "OK: Grafana, Prometheus, Loki e Tempo iniciam com as configs e o endurecimento do compose"
