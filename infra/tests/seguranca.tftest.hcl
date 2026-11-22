# Propriedades de segurança da infraestrutura (T13, ADR-0030, ADR-0032), verificadas com o provider
# da AWS simulado: roda sem credenciais e sem criar nada.
#   terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      address = "cybersec-db.abc.us-east-1.rds.amazonaws.com"
      port    = 5432
      master_user_secret = [{
        secret_arn    = "arn:aws:secretsmanager:us-east-1:111122223333:secret:rds!db-abc"
        kms_key_id    = "arn:aws:kms:us-east-1:111122223333:key/abc"
        secret_status = "active"
      }]
    }
  }
  mock_resource "aws_cloudfront_distribution" {
    defaults = { domain_name = "d111111abcdef8.cloudfront.net" }
  }
  mock_resource "aws_ecr_repository" {
    defaults = { repository_url = "111122223333.dkr.ecr.us-east-1.amazonaws.com/cybersec/modulo" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:111122223333:key/abc" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:111122223333:log-group:mock" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock" }
  }
  mock_resource "aws_service_discovery_http_namespace" {
    defaults = { arn = "arn:aws:servicediscovery:us-east-1:111122223333:namespace/ns-mock" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/app/mock/abc" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111122223333:targetgroup/mock/abc" }
  }
  mock_resource "aws_lb_listener" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111122223333:listener/app/mock/abc/def" }
  }
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111122223333:cluster/cybersec" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:111122223333:cybersec-alertas" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:111122223333:secret:cybersec/mock-abc" }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:us-east-1:111122223333:rule/mock" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock" }
  }
  mock_resource "aws_wafv2_web_acl" {
    defaults = { arn = "arn:aws:wafv2:us-east-1:111122223333:global/webacl/mock/abc" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = {
      arn                  = "arn:aws:ecs:us-east-1:111122223333:task-definition/cybersec-mock:1"
      arn_without_revision = "arn:aws:ecs:us-east-1:111122223333:task-definition/cybersec-mock"
    }
  }
  mock_data "aws_elb_service_account" {
    defaults = { arn = "arn:aws:iam::507241528517:root" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-0123456789abcdef0" }
  }
  mock_resource "aws_codestarconnections_connection" {
    defaults = { arn = "arn:aws:codeconnections:us-east-1:111122223333:connection/mock" }
  }
  mock_resource "aws_codebuild_project" {
    defaults = { arn = "arn:aws:codebuild:us-east-1:111122223333:project/mock" }
  }
  mock_resource "aws_ssm_parameter" {
    defaults = { arn = "arn:aws:ssm:us-east-1:111122223333:parameter/cybersec/imagem_tag" }
  }
  mock_resource "aws_codepipeline" {
    defaults = { arn = "arn:aws:codepipeline:us-east-1:111122223333:cybersec" }
  }
}

mock_provider "aws" {
  alias = "us_east_1"
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_wafv2_web_acl" {
    defaults = { arn = "arn:aws:wafv2:us-east-1:111122223333:global/webacl/mock/abc" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:111122223333:log-group:aws-waf-logs-cybersec" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:111122223333:key/abc" }
  }
}

# O terraform test também lê o terraform.tfvars local; fixa os valores que os asserts verificam.
variables {
  email_alertas            = null
  rds_retencao_backup_dias = 7
}

run "padrao_seguro" {
  command = apply

  # --- Rede ---------------------------------------------------------------------------------
  assert {
    condition     = length(aws_subnet.publica) == 2 && length(aws_subnet.dados) == 2
    error_message = "Cada camada deve ter 2 AZs."
  }
  assert {
    condition     = alltrue([for s in concat(aws_subnet.publica, aws_subnet.borda, aws_subnet.app, aws_subnet.dados) : !coalesce(s.map_public_ip_on_launch, false)])
    error_message = "Nenhuma subnet distribui IP público automaticamente."
  }
  assert {
    condition     = length(aws_route_table.dados.route) == 0
    error_message = "As subnets de dados não podem ter rota para fora da VPC."
  }
  assert {
    condition     = length(aws_nat_gateway.principal) == 1
    error_message = "Padrão acadêmico: NAT único (ADR-0030)."
  }
  assert {
    condition     = length(aws_default_security_group.padrao.ingress) == 0 && length(aws_default_security_group.padrao.egress) == 0
    error_message = "O security group padrão deve ficar sem regras."
  }

  # --- Banco --------------------------------------------------------------------------------
  assert {
    condition     = aws_db_instance.principal.identifier == "cybersec-db"
    error_message = "A instância deve se chamar cybersec-db."
  }
  assert {
    condition     = !aws_db_instance.principal.publicly_accessible && aws_db_instance.principal.storage_encrypted
    error_message = "RDS sem acesso público e cifrado."
  }
  assert {
    condition     = aws_db_instance.principal.manage_master_user_password && aws_db_instance.principal.deletion_protection
    error_message = "Senha mestre gerenciada pelo RDS e proteção contra exclusão."
  }
  assert {
    condition     = aws_db_instance.principal.backup_retention_period == 7
    error_message = "Padrão: backups automáticos por 7 dias."
  }
  assert {
    condition     = !contains(["app_user", "migrator"], aws_db_instance.principal.username)
    error_message = "O usuário mestre não pode ter o nome de uma role da aplicação."
  }
  assert {
    condition = alltrue([
      for p in ["rds.force_ssl=1", "ssl_min_protocol_version=TLSv1.2", "password_encryption=scram-sha-256"] :
      contains([for x in aws_db_parameter_group.principal.parameter : "${x.name}=${x.value}"], p)
    ])
    error_message = "Parameter group sem TLS obrigatório ou sem SCRAM."
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.rds) == 3
    error_message = "O RDS só aceita backend, rotinas e tasks de banco."
  }

  # --- Borda --------------------------------------------------------------------------------
  assert {
    condition     = aws_lb.interno.internal && aws_lb.interno.drop_invalid_header_fields
    error_message = "ALB interno e descartando cabeçalhos inválidos."
  }
  assert {
    condition     = aws_lb_listener.http.default_action[0].type == "fixed-response" && aws_lb_listener.http.default_action[0].fixed_response[0].status_code == "403"
    error_message = "Sem o cabeçalho de origem, o ALB responde 403."
  }
  assert {
    condition     = aws_cloudfront_distribution.principal.default_cache_behavior[0].viewer_protocol_policy == "redirect-to-https"
    error_message = "O CloudFront redireciona HTTP para HTTPS."
  }
  assert {
    condition     = aws_cloudfront_distribution.principal.restrictions[0].geo_restriction[0].locations == toset(["BR"])
    error_message = "Acesso restrito ao Brasil por padrão."
  }
  assert {
    condition     = !contains(aws_cloudfront_origin_request_policy.aplicacao.query_strings_config[0].query_strings[*], "cpf") && aws_cloudfront_origin_request_policy.aplicacao.query_strings_config[0].query_string_behavior == "none"
    error_message = "Query string não chega à origem."
  }

  # --- ECS ----------------------------------------------------------------------------------
  assert {
    condition     = !aws_ecs_service.frontend.network_configuration[0].assign_public_ip && !aws_ecs_service.backend.network_configuration[0].assign_public_ip
    error_message = "Tasks sem IP público."
  }
  assert {
    condition     = aws_ecs_service.frontend.desired_count == 2 && aws_ecs_service.backend.desired_count == 2
    error_message = "Duas tasks de frontend e duas de backend."
  }
  assert {
    condition     = aws_ecs_service.backend.deployment_circuit_breaker[0].rollback && aws_ecs_service.frontend.deployment_circuit_breaker[0].rollback
    error_message = "Deploy com rollback automático."
  }
  assert {
    condition = alltrue(flatten([
      for nome, td in aws_ecs_task_definition.familia : [
        for c in jsondecode(td.container_definitions) : [
          for e in c.environment : length(regexall("PASSWORD|KEK|HMAC|CHECKPOINT|SECRET", e.name)) == 0
        ]
      ]
    ]))
    error_message = "Segredo em variável de ambiente: use secrets (Secrets Manager)."
  }
  assert {
    condition = alltrue([
      for nome, td in aws_ecs_task_definition.familia :
      jsondecode(td.container_definitions)[0].readonlyRootFilesystem == (nome != "administracao")
    ])
    error_message = "Raiz somente leitura em todas as tasks, exceto a de administração (ECS Exec)."
  }
  assert {
    condition     = length(jsondecode(aws_ecs_task_definition.familia["frontend"].container_definitions)[0].secrets) == 0
    error_message = "O frontend não recebe segredo nenhum."
  }
  assert {
    condition = [
      for nome, td in aws_ecs_task_definition.familia : nome
      if contains([for s in jsondecode(td.container_definitions)[0].secrets : s.name], "LOG_CHECKPOINT_KEY")
    ] == ["verificacao-log"]
    error_message = "Só a verificação do log recebe a LOG_CHECKPOINT_KEY (ADR-0010)."
  }
  assert {
    condition = [
      for nome, td in aws_ecs_task_definition.familia : nome
      if contains([for s in jsondecode(td.container_definitions)[0].secrets : s.name], "POSTGRES_PASSWORD")
    ] == ["bootstrap"]
    error_message = "Só o bootstrap recebe a senha do usuário mestre do RDS."
  }
  assert {
    condition = alltrue([
      for e in jsondecode(aws_ecs_task_definition.familia["frontend"].container_definitions)[0].environment :
      e.name != "ORIGEM_PUBLICA" || startswith(e.value, "https://")
    ])
    error_message = "ORIGEM_PUBLICA precisa ser HTTPS (CSRF atrás do CloudFront)."
  }
  assert {
    condition = alltrue(flatten([
      for td in aws_ecs_task_definition.familia : [
        for e in jsondecode(td.container_definitions)[0].environment : e.value == "verify-full" if e.name == "DB_SSLMODE"
      ]
    ]))
    error_message = "Toda conexão ao banco com verify-full."
  }
  assert {
    condition     = aws_ecs_cluster.principal.configuration[0].execute_command_configuration[0].logging == "NONE"
    error_message = "O conteúdo do ECS Exec não é gravado (CPF nos comandos, ADR-0032)."
  }

  # --- Logs e chaves ------------------------------------------------------------------------
  assert {
    condition = alltrue(concat(
      [for g in aws_cloudwatch_log_group.ecs : g.kms_key_id != null && g.retention_in_days >= 365],
      [for g in aws_cloudwatch_log_group.rds : g.kms_key_id != null && g.retention_in_days >= 365],
      [aws_cloudwatch_log_group.flow_logs.kms_key_id != null, aws_cloudwatch_log_group.waf.kms_key_id != null],
    ))
    error_message = "Todo grupo de log cifrado com KMS e retido por 1 ano."
  }
  assert {
    condition     = aws_kms_key.principal.enable_key_rotation
    error_message = "Rotação automática da chave KMS."
  }
  assert {
    condition     = alltrue([for r in aws_ecr_repository.modulo : r.image_tag_mutability == "IMMUTABLE" && r.image_scanning_configuration[0].scan_on_push])
    error_message = "ECR com tags imutáveis e scan na entrada."
  }
}

run "nat_por_az_em_producao" {
  command = plan
  variables {
    nat_por_az = true
  }
  assert {
    condition     = length(aws_nat_gateway.principal) == 2
    error_message = "Com nat_por_az, um NAT por AZ."
  }
}

run "minimo_de_duas_tasks" {
  command = plan
  variables {
    tasks_minimas = 1
  }
  expect_failures = [var.tasks_minimas]
}

run "backup_no_plano_gratuito" {
  command = plan
  variables {
    rds_retencao_backup_dias = 1
  }
  assert {
    condition     = aws_db_instance.principal.backup_retention_period == 1
    error_message = "A retenção do backup segue a variável (plano gratuito, ADR-0034)."
  }
}

run "backup_nunca_desligado" {
  command = plan
  variables {
    rds_retencao_backup_dias = 0
  }
  expect_failures = [var.rds_retencao_backup_dias]
}

# --- Observabilidade (T14, ADR-0037) ------------------------------------------------------------

run "grafana_isolado" {
  command = apply

  assert {
    condition = (
      aws_instance.grafana[0].metadata_options[0].http_tokens == "required"
      && aws_instance.grafana[0].metadata_options[0].http_put_response_hop_limit == 1
    )
    error_message = "IMDSv2 obrigatório, com hop limit 1 (containers fora da rede do host sem credenciais)."
  }
  assert {
    condition     = aws_instance.grafana[0].root_block_device[0].encrypted
    error_message = "Disco da EC2 do Grafana cifrado."
  }
  assert {
    condition     = aws_instance.grafana[0].private_ip == "10.20.0.10" && aws_instance.grafana[0].subnet_id == aws_subnet.publica[0].id
    error_message = "IP privado fixo na subnet pública: é o endpoint OTLP das tasks."
  }
  assert {
    condition = alltrue([
      for r in aws_vpc_security_group_ingress_rule.grafana_otlp :
      r.from_port == 4318 && r.to_port == 4318 && r.cidr_ipv4 == null && r.referenced_security_group_id != null
    ]) && length(aws_vpc_security_group_ingress_rule.grafana_otlp) == 2
    error_message = "Na EC2 do Grafana só entra OTLP 4318, e só dos SGs do frontend e do backend."
  }
  assert {
    condition     = aws_vpc_security_group_egress_rule.grafana_https[0].from_port == 443 && aws_vpc_security_group_egress_rule.grafana_https[0].to_port == 443
    error_message = "A EC2 do Grafana só sai por HTTPS."
  }
  assert {
    condition = alltrue([
      for f in ["frontend", "backend"] : contains(
        [for e in jsondecode(aws_ecs_task_definition.familia[f].container_definitions)[0].environment : "${e.name}=${e.value}"],
        "OTEL_EXPORTER_OTLP_ENDPOINT=http://10.20.0.10:4318"
      )
    ])
    error_message = "Frontend e backend exportam para o Collector da EC2."
  }
  assert {
    condition     = length(aws_instance.grafana[0].user_data_base64) < 21800
    error_message = "user_data acima de 16 KB (limite da EC2)."
  }
}

run "sem_observabilidade" {
  command = plan
  variables {
    observabilidade = false
  }
  assert {
    condition     = length(aws_instance.grafana) == 0 && length(aws_vpc_security_group_egress_rule.otlp) == 0
    error_message = "observabilidade = false remove a EC2 e a saída OTLP."
  }
  assert {
    condition = !contains(
      [for e in jsondecode(aws_ecs_task_definition.familia["backend"].container_definitions)[0].environment : e.name],
      "OTEL_EXPORTER_OTLP_ENDPOINT"
    )
    error_message = "Sem a EC2, as tasks não exportam telemetria."
  }
}

run "grafana_so_em_arm" {
  command = plan
  variables {
    grafana_tipo_instancia = "t3.small"
  }
  expect_failures = [var.grafana_tipo_instancia]
}

# --- CI/CD (T15, ADR-0038) ---------------------------------------------------------------------

run "cicd_antes_da_conexao" {
  command = plan
  variables {
    github_conectado = false
  }
  assert {
    condition     = length(aws_codepipeline.principal) == 0 && length(aws_codebuild_webhook.pr) == 0 && length(aws_codebuild_project.pr) == 0
    error_message = "Sem a conexão concluída, nada que dependa do GitHub é criado."
  }
  assert {
    condition     = strcontains(jsondecode(aws_ecs_task_definition.familia["backend"].container_definitions)[0].image, ":${var.imagem_tag}")
    error_message = "As task definitions usam a tag do parâmetro /cybersec/imagem_tag."
  }
}

run "cicd_menor_privilegio" {
  command = apply
  variables {
    github_conectado = true
  }

  assert {
    condition = length([
      for a in flatten([for st in data.aws_iam_policy_document.codebuild["pr"].statement : st.actions]) : a
      if can(regex("^(ecr|ecs|ssm|secretsmanager|iam|s3|kms|sts):", a))
    ]) == 0
    error_message = "O build dos PRs (código não revisado) não acessa ECR, ECS, SSM, segredos, IAM, S3 nem KMS."
  }
  assert {
    condition = length([
      for a in flatten([for st in data.aws_iam_policy_document.codebuild["verificacao"].statement : st.actions]) : a
      if can(regex("^(ecr|ecs|ssm|secretsmanager|iam|sts):", a))
    ]) == 0
    error_message = "A verificação do pipeline não acessa ECR, ECS, SSM, segredos nem IAM."
  }
  assert {
    condition = alltrue([
      for doc in [data.aws_iam_policy_document.codebuild["implantacao"], data.aws_iam_policy_document.pipeline] :
      length([for st in doc.statement : st if contains(st.actions, "iam:PassRole")]) == 1 && alltrue([
        for st in doc.statement : !contains(st.actions, "iam:PassRole") || (
          !contains(st.resources, "*") && one(st.condition).variable == "iam:PassedToService"
          && toset(one(st.condition).values) == toset(["ecs-tasks.amazonaws.com"])
        )
      ])
    ])
    error_message = "iam:PassRole só em roles nomeadas (nunca *) e só para o ECS, na implantação e no pipeline."
  }
  assert {
    condition = contains(
      flatten([for g in aws_codebuild_webhook.pr[0].filter_group : [for f in g.filter : "${f.type}=${f.pattern}"]]),
      "ACTOR_ACCOUNT_ID=^(205552009)$"
    )
    error_message = "O webhook dos PRs só aceita os atores permitidos."
  }
  assert {
    condition     = aws_codebuild_webhook.pr[0].pull_request_build_policy[0].requires_comment_approval == "FORK_PULL_REQUESTS"
    error_message = "PR de fork só roda com aprovação por comentário."
  }
  assert {
    condition = [for st in aws_codepipeline.principal[0].stage : st.name] == [
      "Fonte", "Verificacao", "Imagens", "Aprovacao", "Migrations", "DeployBackend", "DeployFrontend"
    ]
    error_message = "Aprovação manual antes das migrations e do deploy, nesta ordem."
  }
  assert {
    condition     = alltrue([for a in aws_codepipeline.principal[0].artifact_store : one(a.encryption_key).type == "KMS"])
    error_message = "Artefatos do pipeline cifrados com KMS."
  }
  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.artefatos.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "Bucket de artefatos cifrado com KMS."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.artefatos.block_public_policy && aws_s3_bucket_public_access_block.artefatos.restrict_public_buckets
    error_message = "Bucket de artefatos sem acesso público."
  }
}

run "cicd_ator_obrigatorio" {
  command = plan
  variables {
    github_atores_permitidos = []
  }
  expect_failures = [var.github_atores_permitidos]
}
