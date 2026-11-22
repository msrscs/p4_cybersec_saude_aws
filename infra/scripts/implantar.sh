#!/usr/bin/env bash
# Implanta uma tag já publicada no ECR nas tasks de banco e nas rotinas, e roda as migrations
# (T15, ADR-0038). Usado pelo pipeline (buildspecs/implantacao.yml) e, em contingência, à mão:
#
#   CLUSTER=cybersec REDE_TASKS_BANCO="$(terraform -chdir=infra output -raw rede_tasks_banco)" \
#   ECR_REGISTRO=<conta>.dkr.ecr.us-east-1.amazonaws.com PREFIXO=cybersec \
#   PARAMETRO_TAG=/cybersec/imagem_tag infra/scripts/implantar.sh <tag>
#
# 1. Registra nova revisão de migracao, bootstrap, administracao (imagem db), limpeza e
#    verificacao-log (imagem backend), copiando a revisão atual e trocando só a imagem. O Scheduler
#    usa sempre a última revisão das rotinas.
# 2. Roda a task migracao e falha se ela não terminar com código 0.
# 3. Grava a tag no parâmetro SSM, para o Terraform usar a mesma imagem.
# O backend e o frontend são atualizados depois, pelas ações de deploy ECS do pipeline.
set -euo pipefail

TAG="${1:?uso: $0 <tag>}"
[[ "$TAG" =~ ^[0-9a-zA-Z._-]{1,64}$ ]] || { echo "tag inválida" >&2; exit 1; }
: "${CLUSTER:?}" "${REDE_TASKS_BANCO:?}" "${ECR_REGISTRO:?}" "${PREFIXO:?}" "${PARAMETRO_TAG:?}"
declare -A REPO=([migracao]=db [bootstrap]=db [administracao]=db [limpeza]=backend [verificacao-log]=backend)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A imagem precisa existir antes de qualquer mudança (falha cedo, sem revisão órfã).
for repo in db backend; do
  aws ecr describe-images --repository-name "$PREFIXO/$repo" --image-ids "imageTag=$TAG" >/dev/null
done

for familia in "${!REPO[@]}"; do
  aws ecs describe-task-definition --task-definition "$PREFIXO-$familia" --query taskDefinition \
    --output json >"$TMP/atual.json"
  python3 -I - "$TMP/atual.json" "$ECR_REGISTRO/$PREFIXO/${REPO[$familia]}:$TAG" >"$TMP/nova.json" <<'PY'
import json, sys
td = json.load(open(sys.argv[1]))
for campo in ("taskDefinitionArn", "revision", "status", "requiresAttributes", "compatibilities",
              "registeredAt", "registeredBy", "deregisteredAt"):
    td.pop(campo, None)
(container,) = td["containerDefinitions"]  # uma task, um container (ecs.tf)
container["image"] = sys.argv[2]
print(json.dumps(td))
PY
  revisao="$(aws ecs register-task-definition --cli-input-json "file://$TMP/nova.json" \
    --query taskDefinition.revision --output text)"
  echo "$PREFIXO-$familia:$revisao -> $TAG"
done

echo "Migrations..."
TASK="$(aws ecs run-task --cluster "$CLUSTER" --launch-type FARGATE --task-definition "$PREFIXO-migracao" \
  --network-configuration "$REDE_TASKS_BANCO" --started-by pipeline --query 'tasks[0].taskArn' --output text)"
aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TASK"
SAIDA="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK" \
  --query 'tasks[0].containers[0].exitCode' --output text)"
if [[ "$SAIDA" != 0 ]]; then
  echo "Migration falhou (código $SAIDA). Logs: /ecs/$PREFIXO/migracao" >&2
  exit 1
fi
echo "Migrations aplicadas."

aws ssm put-parameter --name "$PARAMETRO_TAG" --value "$TAG" --overwrite >/dev/null
echo "Tag $TAG registrada em $PARAMETRO_TAG."
