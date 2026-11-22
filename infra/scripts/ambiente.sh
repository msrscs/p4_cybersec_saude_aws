#!/usr/bin/env bash
# Pausa e retoma o ambiente da AWS para economizar fora do horário de uso (ADR-0036): para os
# serviços do ECS (frontend e backend), as rotinas agendadas, o RDS e a EC2 do Grafana (T14).
# Não apaga nada; a telemetria guardada na EC2 sobrevive à pausa.
#
# Uso (na raiz do repositório, com credenciais da AWS):
#   infra/scripts/ambiente.sh status
#   infra/scripts/ambiente.sh pausar
#   infra/scripts/ambiente.sh retomar
#
# Atenção:
# - A AWS religa sozinha um RDS parado depois de 7 dias. Rode `pausar` de novo se precisar.
# - Com o ambiente pausado, não rode `terraform apply`: ele restauraria o auto scaling e as rotinas
#   com o banco parado. Rode `retomar` antes. O `terraform plan` mostra essa diferença, e isso é
#   esperado enquanto o ambiente estiver pausado.
# - Continuam cobrando: NAT Gateway, ALB, WAF, CloudFront (por uso), KMS, Secrets Manager, logs e o
#   armazenamento do RDS e dos backups.
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
REGIAO="${AWS_REGION:-$(terraform -chdir="$RAIZ/infra" output -raw regiao)}"
CLUSTER="$(terraform -chdir="$RAIZ/infra" output -raw cluster)"
BANCO="${BANCO:-cybersec-db}"
SERVICOS=(backend frontend)
ROTINAS=(cybersec-limpeza cybersec-verificacao-log)
# Os mesmos valores de tasks_minimas e tasks_maximas em infra/variables.tf.
TASKS_MIN="${TASKS_MIN:-2}"
TASKS_MAX="${TASKS_MAX:-4}"
# EC2 do Grafana (vazio se observabilidade = false ou antes do primeiro apply da T14).
GRAFANA="$(terraform -chdir="$RAIZ/infra" output -json grafana_instancia 2>/dev/null \
  | python3 -c 'import json,sys; v=json.load(sys.stdin); print(v or "")' 2>/dev/null || true)"

aws_() { aws --region "$REGIAO" "$@"; }

estado_banco() {
  aws_ rds describe-db-instances --db-instance-identifier "$BANCO" \
    --query 'DBInstances[0].DBInstanceStatus' --output text
}

# update-schedule exige a definição completa: lê a atual e só troca o State.
rotinas() {
  local estado=$1 nome
  for nome in "${ROTINAS[@]}"; do
    aws_ scheduler get-schedule --name "$nome" --output json \
      | python3 -c '
import json, sys
atual = json.load(sys.stdin)
campos = {"Name", "GroupName", "ScheduleExpression", "ScheduleExpressionTimezone", "StartDate",
          "EndDate", "Description", "KmsKeyArn", "Target", "FlexibleTimeWindow",
          "ActionAfterCompletion"}
novo = {k: v for k, v in atual.items() if k in campos}
novo["State"] = sys.argv[1]
print(json.dumps(novo, default=str))
' "$estado" >"$TMP/rotina.json"
    aws_ scheduler update-schedule --cli-input-json "file://$TMP/rotina.json" >/dev/null
    echo "  rotina $nome: $estado"
  done
}

escala() {
  local minimo=$1 maximo=$2 desejado=$3 servico
  for servico in "${SERVICOS[@]}"; do
    aws_ application-autoscaling register-scalable-target --service-namespace ecs \
      --scalable-dimension ecs:service:DesiredCount \
      --resource-id "service/$CLUSTER/$servico" --min-capacity "$minimo" --max-capacity "$maximo"
    aws_ ecs update-service --cluster "$CLUSTER" --service "$servico" \
      --desired-count "$desejado" >/dev/null
    echo "  serviço $servico: $desejado tasks (auto scaling $minimo-$maximo)"
  done
  echo "  aguardando os serviços estabilizarem..."
  aws_ ecs wait services-stable --cluster "$CLUSTER" --services "${SERVICOS[@]}"
}

estado_grafana() {
  aws_ ec2 describe-instances --instance-ids "$GRAFANA" \
    --query 'Reservations[0].Instances[0].State.Name' --output text
}

grafana() {
  [[ -n "$GRAFANA" ]] || return 0
  if [[ $1 == parar ]]; then
    aws_ ec2 stop-instances --instance-ids "$GRAFANA" >/dev/null
    echo "  EC2 do Grafana: parando"
  else
    aws_ ec2 start-instances --instance-ids "$GRAFANA" >/dev/null
    aws_ ec2 wait instance-running --instance-ids "$GRAFANA"
    echo "  EC2 do Grafana: ligada (a pilha sobe pelo systemd em 1-2 min)"
  fi
}

status() {
  echo "Banco $BANCO: $(estado_banco)"
  [[ -z "$GRAFANA" ]] || echo "EC2 do Grafana $GRAFANA: $(estado_grafana)"
  aws_ ecs describe-services --cluster "$CLUSTER" --services "${SERVICOS[@]}" \
    --query 'services[].[serviceName,runningCount,desiredCount]' --output text \
    | while read -r nome rodando desejado; do
      echo "Serviço $nome: $rodando rodando de $desejado"
    done
  local nome
  for nome in "${ROTINAS[@]}"; do
    echo "Rotina $nome: $(aws_ scheduler get-schedule --name "$nome" --query State --output text)"
  done
}

pausar() {
  echo "Pausando (rotinas -> serviços -> Grafana -> banco):"
  rotinas DISABLED
  escala 0 0 0
  grafana parar
  case "$(estado_banco)" in
    available)
      aws_ rds stop-db-instance --db-instance-identifier "$BANCO" >/dev/null
      echo "  banco $BANCO: parando (leva alguns minutos; a AWS o religa em 7 dias)"
      ;;
    stopped | stopping) echo "  banco $BANCO: já parado" ;;
    *) echo "  banco $BANCO: estado $(estado_banco); não foi parado" >&2 ;;
  esac
}

retomar() {
  echo "Retomando (banco e Grafana -> serviços -> rotinas):"
  grafana ligar
  case "$(estado_banco)" in
    stopped)
      aws_ rds start-db-instance --db-instance-identifier "$BANCO" >/dev/null
      echo "  banco $BANCO: ligando..."
      ;;
    stopping)
      echo "  banco $BANCO: ainda parando; aguarde e rode de novo" >&2
      exit 1
      ;;
  esac
  aws_ rds wait db-instance-available --db-instance-identifier "$BANCO"
  echo "  banco $BANCO: disponível"
  escala "$TASKS_MIN" "$TASKS_MAX" "$TASKS_MIN"
  rotinas ENABLED
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

case "${1:-}" in
  status) status ;;
  pausar) pausar && echo && status ;;
  retomar) retomar && echo && status ;;
  *)
    echo "Uso: $0 status|pausar|retomar" >&2
    exit 2
    ;;
esac
