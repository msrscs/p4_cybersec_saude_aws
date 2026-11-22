# Rotinas periódicas pelo EventBridge Scheduler, como tasks avulsas da imagem do backend
# (ADR-0029): limpeza a cada 15 min e verificação da cadeia do log a cada hora. Uma task de
# rotina ou de banco que termina com erro gera alerta no SNS.

data "aws_iam_policy_document" "assumir_scheduler" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.conta]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.nome}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.assumir_scheduler.json
}

locals {
  # Família da task -> frequência.
  rotinas = {
    "limpeza"         = "rate(15 minutes)"
    "verificacao-log" = "rate(1 hour)"
  }
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["ecs:RunTask"]
    resources = [for r in keys(local.rotinas) : "${aws_ecs_task_definition.familia[r].arn_without_revision}:*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.principal.arn]
    }
  }
  statement {
    actions   = ["iam:PassRole"]
    resources = [for r in keys(local.rotinas) : aws_iam_role.execucao[r].arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "rodar-rotinas"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "rotina" {
  #checkov:skip=CKV_AWS_297:sem entrada; a task definition já traz o comando
  for_each                     = local.rotinas
  name                         = "${local.nome}-${each.key}"
  schedule_expression          = each.value
  schedule_expression_timezone = "America/Recife"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_ecs_cluster.principal.arn
    role_arn = aws_iam_role.scheduler.arn

    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.familia[each.key].arn_without_revision
      launch_type         = "FARGATE"
      platform_version    = "LATEST"
      network_configuration {
        subnets          = aws_subnet.app[*].id
        security_groups  = [aws_security_group.tarefas.id]
        assign_public_ip = false
      }
    }

    retry_policy {
      maximum_retry_attempts = 0
    }
  }
}

# --- Alertas ----------------------------------------------------------------------------------

resource "aws_sns_topic" "alertas" {
  name              = "${local.nome}-alertas"
  kms_master_key_id = aws_kms_key.principal.arn
}

data "aws_iam_policy_document" "alertas" {
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alertas.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = concat([aws_cloudwatch_event_rule.task_com_erro.arn], aws_cloudwatch_event_rule.pipeline_falhou[*].arn)
    }
  }
}

resource "aws_sns_topic_policy" "alertas" {
  arn    = aws_sns_topic.alertas.arn
  policy = data.aws_iam_policy_document.alertas.json
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.email_alertas == null ? 0 : 1
  topic_arn = aws_sns_topic.alertas.arn
  protocol  = "email"
  endpoint  = var.email_alertas
}

# Cadeia do log quebrada termina com código 1 (ADR-0010, ADR-0029): avisa na hora.
resource "aws_cloudwatch_event_rule" "task_com_erro" {
  name        = "${local.nome}-task-com-erro"
  description = "Rotina, migration ou bootstrap terminou com erro"
  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Task State Change"]
    detail = {
      clusterArn = [aws_ecs_cluster.principal.arn]
      lastStatus = ["STOPPED"]
      group      = [for f in ["limpeza", "verificacao-log", "migracao", "bootstrap"] : "family:${local.nome}-${f}"]
      containers = { exitCode = [{ "anything-but" = 0 }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "task_com_erro" {
  rule      = aws_cloudwatch_event_rule.task_com_erro.name
  target_id = "sns"
  arn       = aws_sns_topic.alertas.arn
  input_transformer {
    input_paths = {
      grupo  = "$.detail.group"
      motivo = "$.detail.stoppedReason"
    }
    input_template = "\"CyberSec Saude: a task <grupo> terminou com erro (<motivo>). Veja os logs em /ecs/cybersec/.\""
  }
}
