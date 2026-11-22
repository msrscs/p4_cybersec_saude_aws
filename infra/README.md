# Infraestrutura AWS (Terraform)

Implementa o ADR-0030 e o ADR-0032. Os comandos abaixo partem da raiz do repositório e exigem credenciais da AWS (`aws login`), Terraform >= 1.11 e Docker.

```
CloudFront (*.cloudfront.net, WAF, só BR) ──VPC Origin──> ALB interno (subnets de borda)
  -> frontend x2 (subnets de app) ──Service Connect──> backend x2 ──TLS verify-full──> RDS cybersec-db
EventBridge Scheduler -> limpeza (15 min), verificacao-log (1 h)
Tasks avulsas: migracao, bootstrap, administracao (ECS Exec)
```

| Arquivo | Conteúdo |
|---|---|
| `bootstrap/` | Bucket S3 do state (uma vez, state local) |
| `rede.tf` | VPC em 2 AZs, 4 camadas, NAT, endpoint S3, Flow Logs |
| `seguranca.tf` | Security groups em cadeia (origem única) |
| `kms.tf`, `segredos.tf` | Chave KMS e Secrets Manager |
| `banco.tf` | RDS PostgreSQL 18 `cybersec-db` |
| `ecr.tf`, `ecs.tf` | Repositórios, cluster, task definitions, serviços, auto scaling |
| `alb.tf`, `cloudfront.tf` | ALB interno, CloudFront, VPC Origin, WAF |
| `rotinas.tf` | Scheduler e alertas (SNS) |
| `tests/` | `terraform test` com provider simulado (sem credenciais) |

## Validação local (sem conta AWS)

```bash
cd infra
terraform init -backend=false
terraform fmt -check -recursive && terraform validate && terraform test
checkov -d . --framework terraform --skip-path .terraform   # 0 falhas; exceções justificadas no código
```

## Primeira implantação

1. **State remoto** (uma vez):
   ```bash
   terraform -chdir=infra/bootstrap init && terraform -chdir=infra/bootstrap apply
   cp infra/backend.hcl.example infra/backend.hcl          # troque <conta>
   cp infra/exemplo.tfvars infra/terraform.tfvars          # e-mail de alertas
   terraform -chdir=infra init -backend-config=backend.hcl
   ```
2. **Repositórios e imagens.** Os serviços só sobem com as imagens no ECR:
   ```bash
   terraform -chdir=infra apply -target=aws_ecr_repository.modulo
   REG=$(terraform -chdir=infra output -json ecr | jq -r .backend | cut -d/ -f1)
   aws ecr get-login-password | docker login --username AWS --password-stdin "$REG"
   docker build -t "$REG/cybersec/frontend:inicial" frontend
   docker build -t "$REG/cybersec/backend:inicial" backend
   docker build -f db/Dockerfile -t "$REG/cybersec/db:inicial" .
   for m in frontend backend db; do docker push "$REG/cybersec/$m:inicial"; done
   ```
   Para `arquitetura = "ARM64"`, use `docker build --platform linux/arm64`.
3. **Todo o resto:**
   ```bash
   terraform -chdir=infra apply
   ```
   Os serviços tentam subir e falham até os passos 4 e 5. O circuit breaker para o deploy; depois do passo 5, force um novo deploy.
4. **Chaves da aplicação** (KEK, HMAC e checkpoint do log), geradas pelo `scripts.gerar_chaves`. O script só preenche segredos vazios:
   ```bash
   infra/scripts/popular_chaves.sh
   ```
5. **Banco:** bootstrap das roles, migrations e catálogo do CID:
   ```bash
   C=$(terraform -chdir=infra output -raw cluster)
   REDE=$(terraform -chdir=infra output -raw rede_tasks_banco)
   rodar() { aws ecs run-task --cluster "$C" --launch-type FARGATE --network-configuration "$REDE" "$@" \
     --query 'tasks[0].taskArn' --output text; }
   T=$(rodar --task-definition cybersec-bootstrap); aws ecs wait tasks-stopped --cluster "$C" --tasks "$T"
   T=$(rodar --task-definition cybersec-migracao);  aws ecs wait tasks-stopped --cluster "$C" --tasks "$T"
   T=$(rodar --task-definition cybersec-administracao \
     --overrides '{"containerOverrides":[{"name":"administracao","command":["python","-m","scripts.importar_cid"]}]}')
   aws ecs wait tasks-stopped --cluster "$C" --tasks "$T"
   aws ecs describe-tasks --cluster "$C" --tasks "$T" --query 'tasks[0].containers[0].exitCode'   # 0
   # Cadastros de catálogo (db/seeds/cadastros.json, ADR-0035), depois do CID:
   T=$(rodar --task-definition cybersec-administracao \
     --overrides '{"containerOverrides":[{"name":"administracao","command":["python","-m","scripts.importar_cadastros"]}]}')
   aws ecs wait tasks-stopped --cluster "$C" --tasks "$T"
   aws ecs describe-tasks --cluster "$C" --tasks "$T" --query 'tasks[0].containers[0].exitCode'   # 0
   for s in backend frontend; do aws ecs update-service --cluster "$C" --service $s --force-new-deployment >/dev/null; done
   ```
   Uma task de banco ou de rotina que termina com erro gera alerta no SNS. Os logs ficam em `/ecs/cybersec/<família>`.
6. **Primeiro administrador**, pela task de administração com ECS Exec (requer o Session Manager plugin):
   ```bash
   T=$(rodar --task-definition cybersec-administracao --enable-execute-command)
   aws ecs wait tasks-running --cluster "$C" --tasks "$T"
   aws ecs execute-command --cluster "$C" --task "$T" --container administracao --interactive --command "/bin/sh"
   # dentro da sessão:
   python -m scripts.criar_usuario --cpf ... --nome "..." --email ...    # senha por getpass
   python -m scripts.atribuir_grupo --cpf ... --grupo Administrador   # digite CONFIRMAR quando pedir
   exit
   aws ecs stop-task --cluster "$C" --task "$T" >/dev/null
   ```
   Use `/bin/sh` e digite o comando dentro da sessão. Passado por `--command`, o CPF ficaria registrado no CloudTrail. O conteúdo da sessão não é gravado (ADR-0032). A criação do usuário e a mudança de grupo ficam no log WORM da aplicação, e a abertura da sessão fica no CloudTrail. A task se encerra sozinha em 1 h.
7. **Conferir:** abra `terraform -chdir=infra output -raw url`, faça o login com MFA e veja na consulta do log se o `ip_origem` é o seu IP real, e não um IP 10.20.x.x. Isso confirma a cadeia CloudFront → ALB → frontend → Service Connect → backend (ADR-0029, ADR-0032).

## Operação

- **Deploy de uma nova versão:** feito pelo pipeline (T15). Os serviços ignoram mudanças de `task_definition` no Terraform para não desfazer o deploy do pipeline. Depois de mudar variáveis de ambiente pelo Terraform, rode `aws ecs update-service --cluster cybersec --service <s> --task-definition cybersec-<s>` (última revisão).
- **Senhas das roles do banco:** incremente `versao_senhas_banco` em `segredos.tf`, rode `apply`, depois a task `cybersec-bootstrap` (que atualiza a senha das roles) e force o deploy de backend e frontend.
- **Cabeçalho secreto de origem:** `terraform apply -replace=random_password.origem`.
- **KEK:** a rotação ainda não recifra as DEKs antigas (THREAT_MODEL, T10). Não troque o segredo `cybersec/chaves-aplicacao` à mão. **HMAC_KEY e LOG_CHECKPOINT_KEY nunca mudam.**
- **Custo:** NAT, ALB, RDS, 4 tasks, WAF e CloudFront ficam ligados o tempo todo. Para pausar e retomar o ECS e o RDS (ADR-0036):
  ```bash
  infra/scripts/ambiente.sh status
  infra/scripts/ambiente.sh pausar    # rotinas -> serviços (0 tasks) -> RDS parado
  infra/scripts/ambiente.sh retomar   # RDS -> serviços (2 tasks) -> rotinas
  ```
  - **Retomar** leva de 5 a 10 minutos, quase tudo esperando o RDS.
  - **O RDS religa sozinho em 7 dias.** Se precisar, rode `pausar` de novo.
  - **Com o ambiente pausado, não rode `terraform apply`**, porque ele religaria o auto scaling e as rotinas com o banco parado. Rode `retomar` antes. Enquanto estiver pausado, o `plan` mostra essa diferença.
  - **Continuam cobrando:** NAT Gateway, ALB, WAF, KMS, Secrets Manager, logs e o armazenamento do RDS.
