# ECS Fargate (ADR-0029, ADR-0030, ADR-0032).
#
# Serviços sempre ligados: frontend e backend, 2+ tasks cada (uma por AZ), subnets de app, sem IP
# público. Tasks avulsas: limpeza e verificacao-log (Scheduler), migracao, bootstrap e
# administracao (ECS Exec).
# Cada família tem a própria execution role e só recebe os segredos de que precisa.

locals {
  url_repo   = { for k, r in aws_ecr_repository.modulo : k => r.repository_url }
  rds_mestre = aws_db_instance.principal.master_user_secret[0].secret_arn

  # Nome da variável no container -> valueFrom (ARN, ou ARN:chave:: para segredos JSON).
  segredo = {
    APP_DB_PASSWORD      = aws_secretsmanager_secret.app_db.arn
    MIGRATOR_DB_PASSWORD = aws_secretsmanager_secret.migrator_db.arn
    KEK_KEYRING          = "${aws_secretsmanager_secret.chaves.arn}:KEK_KEYRING::"
    KEK_ATIVA            = "${aws_secretsmanager_secret.chaves.arn}:KEK_ATIVA::"
    HMAC_KEY             = "${aws_secretsmanager_secret.chaves.arn}:HMAC_KEY::"
    LOG_CHECKPOINT_KEY   = aws_secretsmanager_secret.log_checkpoint.arn
    POSTGRES_USER        = "${local.rds_mestre}:username::"
    POSTGRES_PASSWORD    = "${local.rds_mestre}:password::"
  }
  arn_segredo = {
    APP_DB_PASSWORD      = aws_secretsmanager_secret.app_db.arn
    MIGRATOR_DB_PASSWORD = aws_secretsmanager_secret.migrator_db.arn
    KEK_KEYRING          = aws_secretsmanager_secret.chaves.arn
    KEK_ATIVA            = aws_secretsmanager_secret.chaves.arn
    HMAC_KEY             = aws_secretsmanager_secret.chaves.arn
    LOG_CHECKPOINT_KEY   = aws_secretsmanager_secret.log_checkpoint.arn
    POSTGRES_USER        = local.rds_mestre
    POSTGRES_PASSWORD    = local.rds_mestre
  }
  chaves_app = ["APP_DB_PASSWORD", "KEK_KEYRING", "KEK_ATIVA", "HMAC_KEY"]

  env_banco = [
    { name = "ENVIRONMENT", value = "prod" },
    { name = "POSTGRES_DB", value = var.nome_banco },
    { name = "DB_HOST", value = aws_db_instance.principal.address },
    { name = "DB_PORT", value = tostring(aws_db_instance.principal.port) },
    { name = "DB_SSLMODE", value = "verify-full" },
    { name = "DB_SSLROOTCERT", value = local.ca_rds },
  ]
  env_otel = local.otlp_endpoint == null ? [] : [
    { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = local.otlp_endpoint },
  ]

  familias = {
    frontend = {
      repo    = "frontend", cpu = var.frontend_cpu, memoria = var.frontend_memoria, segredos = []
      comando = null, porta = { name = "web", containerPort = 3000 }, somente_leitura = true
      saude   = ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      env = concat([
        { name = "NODE_ENV", value = "production" },
        { name = "TLS_NA_BORDA", value = "true" },
        { name = "API_URL", value = "http://backend:8000" },
        { name = "ORIGEM_PUBLICA", value = "https://${aws_cloudfront_distribution.principal.domain_name}" },
        # Só o ALB (subnets de borda) informa o IP do usuário, pelo cabeçalho do CloudFront.
        { name = "PROXIES_CONFIAVEIS", value = join(",", local.cidrs.borda) },
        { name = "IP_CLIENTE_HEADER", value = "cloudfront-viewer-address" },
        { name = "OTEL_SERVICE_NAME", value = "cybersec-frontend" },
      ], local.env_otel)
    }
    backend = {
      repo    = "backend", cpu = var.backend_cpu, memoria = var.backend_memoria, segredos = local.chaves_app
      comando = null, porta = { name = "api", containerPort = 8000 }, somente_leitura = true
      saude   = ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"]
      env = concat(local.env_banco, [
        # O proxy do Service Connect entrega na própria task (127.0.0.1); o frontend fica nas
        # subnets de app. Só eles podem informar X-Forwarded-For (IP real para a auditoria).
        { name = "FORWARDED_ALLOW_IPS", value = join(",", concat(["127.0.0.1"], local.cidrs.app)) },
        { name = "OTEL_SERVICE_NAME", value = "cybersec-backend" },
      ], local.env_otel)
    }
    # Rotinas (rotinas.tf): uma família por rotina; só a verificação recebe a chave do checkpoint.
    limpeza = {
      repo    = "backend", cpu = 256, memoria = 512, segredos = local.chaves_app
      comando = ["python", "-m", "scripts.tarefas", "limpar"], porta = null, somente_leitura = true
      saude   = null, env = local.env_banco
    }
    verificacao-log = {
      repo    = "backend", cpu = 256, memoria = 512, segredos = concat(local.chaves_app, ["LOG_CHECKPOINT_KEY"])
      comando = ["python", "-m", "scripts.tarefas", "verificar-log"], porta = null, somente_leitura = true
      saude   = null, env = local.env_banco
    }
    migracao = {
      repo    = "db", cpu = 256, memoria = 512, segredos = ["MIGRATOR_DB_PASSWORD"]
      comando = null, porta = null, somente_leitura = true, saude = null, env = local.env_banco
    }
    bootstrap = {
      repo     = "db", cpu = 256, memoria = 512
      segredos = ["POSTGRES_USER", "POSTGRES_PASSWORD", "APP_DB_PASSWORD", "MIGRATOR_DB_PASSWORD"]
      comando  = ["python", "-m", "scripts.bootstrap_db"], porta = null, somente_leitura = true
      saude    = null, env = local.env_banco
    }
    # Aberta sob demanda para os scripts interativos (criar_usuario etc.) por ECS Exec, ou com
    # o comando trocado para a importação do CID. O agente do ECS Exec precisa gravar no disco.
    administracao = {
      repo    = "db", cpu = 256, memoria = 512, segredos = local.chaves_app
      comando = ["sleep", "3600"], porta = null, somente_leitura = false, saude = null
      env     = local.env_banco
    }
  }

  containers = {
    for nome, f in local.familias : nome => merge(
      {
        name                   = nome
        image                  = "${local.url_repo[f.repo]}:${var.imagem_tag}"
        essential              = true
        environment            = f.env
        secrets                = [for s in f.segredos : { name = s, valueFrom = local.segredo[s] }]
        readonlyRootFilesystem = f.somente_leitura
        mountPoints            = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]
        linuxParameters = {
          initProcessEnabled = true
          capabilities       = { add = [], drop = ["ALL"] }
        }
        # Campos que o ECS devolve preenchidos; declarados para o plan não acusar diferença.
        portMappings   = []
        systemControls = []
        volumesFrom    = []
        stopTimeout    = 30
        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = aws_cloudwatch_log_group.ecs[nome].name
            awslogs-region        = var.regiao
            awslogs-stream-prefix = "ecs"
          }
        }
      },
      f.comando == null ? {} : { command = f.comando },
      f.porta == null ? {} : {
        portMappings = [merge(f.porta, { hostPort = f.porta.containerPort, protocol = "tcp", appProtocol = "http" })]
      },
      # O ECS ignora o HEALTHCHECK do Dockerfile; precisa estar aqui (ADR-0029).
      f.saude == null ? {} : {
        healthCheck = { command = f.saude, interval = 15, timeout = 5, retries = 3, startPeriod = 20 }
      },
    )
  }
}

resource "aws_cloudwatch_log_group" "ecs" {
  for_each          = local.familias
  name              = "/ecs/${local.nome}/${each.key}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.principal.arn
}

# --- IAM ------------------------------------------------------------------------------------

data "aws_iam_policy_document" "assumir_ecs" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.conta]
    }
  }
}

resource "aws_iam_role" "execucao" {
  for_each           = local.familias
  name               = "${local.nome}-execucao-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.assumir_ecs.json
}

data "aws_iam_policy_document" "execucao" {
  for_each = local.familias

  statement {
    sid       = "TokenDoEcr"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "ImagemDoModulo"
    actions   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
    resources = [aws_ecr_repository.modulo[each.value.repo].arn]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.ecs[each.key].arn}:*"]
  }

  dynamic "statement" {
    for_each = length(each.value.segredos) > 0 ? [1] : []
    content {
      sid       = "SoOsProprios"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = distinct([for s in each.value.segredos : local.arn_segredo[s]])
    }
  }
  dynamic "statement" {
    for_each = length(each.value.segredos) > 0 ? [1] : []
    content {
      sid       = "DecifrarSegredos"
      actions   = ["kms:Decrypt"]
      resources = [aws_kms_key.principal.arn]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${var.regiao}.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role_policy" "execucao" {
  for_each = local.familias
  name     = "execucao"
  role     = aws_iam_role.execucao[each.key].id
  policy   = data.aws_iam_policy_document.execucao[each.key].json
}

# Só a task de administração tem task role: os canais do ECS Exec (SSM).
resource "aws_iam_role" "administracao" {
  name               = "${local.nome}-task-administracao"
  assume_role_policy = data.aws_iam_policy_document.assumir_ecs.json
}

data "aws_iam_policy_document" "administracao" {
  statement {
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.principal.arn]
  }
}

resource "aws_iam_role_policy" "administracao" {
  name   = "ecs-exec"
  role   = aws_iam_role.administracao.id
  policy = data.aws_iam_policy_document.administracao.json
}

# --- Cluster e task definitions --------------------------------------------------------------

resource "aws_service_discovery_http_namespace" "principal" {
  name        = "${local.nome}.local"
  description = "Service Connect (frontend -> backend)"
}

resource "aws_ecs_cluster" "principal" {
  #checkov:skip=CKV_AWS_223:conteúdo do ECS Exec não é gravado de propósito (CPF nos comandos, ADR-0032)
  name = local.nome

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  # Sessões do ECS Exec cifradas com KMS. O conteúdo não é gravado: comandos como criar_usuario
  # levam CPF; o log WORM da aplicação registra as operações e o CloudTrail registra quem abriu a
  # sessão (ADR-0032).
  configuration {
    execute_command_configuration {
      kms_key_id = aws_kms_key.principal.arn
      logging    = "NONE"
    }
  }

  service_connect_defaults {
    namespace = aws_service_discovery_http_namespace.principal.arn
  }
}

resource "aws_ecs_cluster_capacity_providers" "principal" {
  cluster_name       = aws_ecs_cluster.principal.name
  capacity_providers = ["FARGATE"]
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

resource "aws_ecs_task_definition" "familia" {
  for_each                 = local.familias
  family                   = "${local.nome}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memoria
  execution_role_arn       = aws_iam_role.execucao[each.key].arn
  task_role_arn            = each.key == "administracao" ? aws_iam_role.administracao.arn : null
  container_definitions    = jsonencode([local.containers[each.key]])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.arquitetura
  }

  # /tmp gravável com a raiz somente leitura (o Fargate não tem tmpfs).
  volume {
    name = "tmp"
  }
}

# --- Serviços ---------------------------------------------------------------------------------

resource "aws_ecs_service" "backend" {
  name                   = "backend"
  cluster                = aws_ecs_cluster.principal.id
  task_definition        = aws_ecs_task_definition.familia["backend"].arn
  desired_count          = var.tasks_minimas
  launch_type            = "FARGATE"
  platform_version       = "LATEST"
  enable_execute_command = false
  propagate_tags         = "SERVICE"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.backend.id]
    assign_public_ip = false
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.principal.arn
    service {
      port_name      = "api"
      discovery_name = "backend"
      client_alias {
        port     = 8000
        dns_name = "backend"
      }
    }
  }

  # desired_count: auto scaling. task_definition: o pipeline (T15) registra novas revisões.
  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }
}

resource "aws_ecs_service" "frontend" {
  name                              = "frontend"
  cluster                           = aws_ecs_cluster.principal.id
  task_definition                   = aws_ecs_task_definition.familia["frontend"].arn
  desired_count                     = var.tasks_minimas
  launch_type                       = "FARGATE"
  platform_version                  = "LATEST"
  enable_execute_command            = false
  propagate_tags                    = "SERVICE"
  health_check_grace_period_seconds = 30

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.frontend.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.frontend.arn
    container_name   = "frontend"
    container_port   = 3000
  }

  # Só cliente do Service Connect: resolve "backend".
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.principal.arn
  }

  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  depends_on = [aws_lb_listener_rule.cloudfront, aws_ecs_service.backend]
}

# --- Auto scaling por CPU -------------------------------------------------------------------

resource "aws_appautoscaling_target" "servico" {
  for_each           = { frontend = aws_ecs_service.frontend.name, backend = aws_ecs_service.backend.name }
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.principal.name}/${each.value}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.tasks_minimas
  max_capacity       = var.tasks_maximas
}

resource "aws_appautoscaling_policy" "cpu" {
  for_each           = aws_appautoscaling_target.servico
  name               = "${local.nome}-${each.key}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = each.value.service_namespace
  resource_id        = each.value.resource_id
  scalable_dimension = each.value.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
