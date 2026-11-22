#!/usr/bin/env bash
# Abre o Grafana (T14, ADR-0037) em http://localhost:3000 por port forwarding do SSM Session Manager.
# Não há porta aberta para a internet nem SSH: a autenticação é a da IAM, e cada sessão fica no
# CloudTrail. Requer o Session Manager plugin.
#
# Uso (na raiz do repositório, com credenciais da AWS):
#   infra/scripts/grafana.sh            # abre o túnel; Ctrl+C fecha
#   infra/scripts/grafana.sh senha      # mostra a senha do admin (fica no histórico do terminal)
#
# PORTA_LOCAL muda a porta no seu computador (padrão 3000).
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
REGIAO="${AWS_REGION:-$(terraform -chdir="$RAIZ/infra" output -raw regiao)}"
INSTANCIA="$(terraform -chdir="$RAIZ/infra" output -json grafana_instancia \
  | python3 -c 'import json,sys; print(json.load(sys.stdin) or "")')"
[[ -n "$INSTANCIA" ]] || { echo "Sem EC2 do Grafana (observabilidade = false?)." >&2; exit 1; }

case "${1:-tunel}" in
  senha)
    aws --region "$REGIAO" secretsmanager get-secret-value --secret-id cybersec/grafana-admin \
      --query SecretString --output text
    ;;
  tunel)
    command -v session-manager-plugin >/dev/null || {
      echo "Instale o Session Manager plugin (infra/README.md, passo 6)." >&2
      exit 1
    }
    estado="$(aws --region "$REGIAO" ec2 describe-instances --instance-ids "$INSTANCIA" \
      --query 'Reservations[0].Instances[0].State.Name' --output text)"
    [[ $estado == running ]] || { echo "EC2 do Grafana: $estado (ambiente.sh retomar?)." >&2; exit 1; }
    echo "Grafana em http://localhost:${PORTA_LOCAL:-3000} (usuário admin; senha: $0 senha). Ctrl+C fecha."
    aws --region "$REGIAO" ssm start-session --target "$INSTANCIA" \
      --document-name AWS-StartPortForwardingSession \
      --parameters "portNumber=3000,localPortNumber=${PORTA_LOCAL:-3000}"
    ;;
  *)
    echo "Uso: $0 [tunel|senha]" >&2
    exit 2
    ;;
esac
