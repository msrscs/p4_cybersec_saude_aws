# ALB interno nas subnets privadas de borda, alcançado só pelo CloudFront VPC Origin (ADR-0030).
# Sem domínio próprio não há certificado: o listener é HTTP, dentro da rede da AWS (risco aceito).
# Sem o cabeçalho X-Origin-Verify correto, a resposta é 403.

resource "aws_s3_bucket" "logs_alb" {
  #checkov:skip=CKV_AWS_145:logs de acesso do ALB só aceitam SSE-S3
  #checkov:skip=CKV_AWS_144:replicação entre regiões fora do escopo acadêmico
  #checkov:skip=CKV_AWS_18:é o próprio bucket de logs
  #checkov:skip=CKV2_AWS_62:sem consumidor de eventos
  bucket        = "${local.nome}-logs-alb-${local.conta}"
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "logs_alb" {
  bucket                  = aws_s3_bucket.logs_alb.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "logs_alb" {
  bucket = aws_s3_bucket.logs_alb.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Logs de acesso do ALB só aceitam SSE-S3.
resource "aws_s3_bucket_server_side_encryption_configuration" "logs_alb" {
  bucket = aws_s3_bucket.logs_alb.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs_alb" {
  bucket = aws_s3_bucket.logs_alb.id
  rule {
    id     = "expirar"
    status = "Enabled"
    filter {}
    expiration {
      days = 365
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Versionado: um log apagado ou sobrescrito continua recuperável por 30 dias.
resource "aws_s3_bucket_versioning" "logs_alb" {
  bucket = aws_s3_bucket.logs_alb.id
  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_elb_service_account" "regiao" {}

data "aws_iam_policy_document" "logs_alb" {
  statement {
    sid       = "EntregaDoElb"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs_alb.arn}/alb/AWSLogs/${local.conta}/*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.regiao.arn]
    }
  }
  statement {
    sid       = "SoTLS"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.logs_alb.arn, "${aws_s3_bucket.logs_alb.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "logs_alb" {
  bucket = aws_s3_bucket.logs_alb.id
  policy = data.aws_iam_policy_document.logs_alb.json
}

resource "aws_lb" "interno" {
  #checkov:skip=CKV2_AWS_20:sem certificado não há HTTPS para onde redirecionar (ADR-0030)
  name                       = "${local.nome}-alb"
  internal                   = true
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.borda[*].id
  drop_invalid_header_fields = true
  desync_mitigation_mode     = "strictest"
  enable_deletion_protection = var.protecao_exclusao
  idle_timeout               = 60

  access_logs {
    bucket  = aws_s3_bucket.logs_alb.id
    prefix  = "alb"
    enabled = true
  }

  depends_on = [aws_s3_bucket_policy.logs_alb]
}

resource "aws_lb_target_group" "frontend" {
  #checkov:skip=CKV_AWS_378:HTTP dentro da VPC até a task, risco aceito no ADR-0029
  name                 = "${local.nome}-frontend"
  port                 = 3000
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.principal.id
  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  #checkov:skip=CKV_AWS_2:sem domínio próprio não há certificado; ALB interno, só VPC Origin (ADR-0030)
  #checkov:skip=CKV_AWS_103:idem: sem listener TLS
  load_balancer_arn = aws_lb.interno.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"detail\":\"Acesso negado.\"}"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "cloudfront" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origem.result]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}
