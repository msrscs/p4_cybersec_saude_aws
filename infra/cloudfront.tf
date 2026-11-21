# CloudFront com o domínio padrão (*.cloudfront.net), VPC Origin para o ALB interno e WAF
# (ADR-0030, ADR-0032). Sem cache: páginas e API são sempre buscadas na origem.

resource "aws_cloudfront_vpc_origin" "alb" {
  vpc_origin_endpoint_config {
    name                   = "${local.nome}-alb"
    arn                    = aws_lb.interno.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}

data "aws_cloudfront_cache_policy" "sem_cache" {
  name = "Managed-CachingDisabled"
}

# Só o que a aplicação usa chega à origem (ADR-0029): cookies, Origin/Sec-Fetch-Site (CSRF,
# 1ª camada), X-CSRF-Token, Content-Type e o IP do usuário gerado pelo CloudFront. Query string
# não: nenhuma rota usa.
resource "aws_cloudfront_origin_request_policy" "aplicacao" {
  name    = "${local.nome}-aplicacao"
  comment = "Cookies e cabecalhos usados pelo CyberSec Saude"

  cookies_config {
    cookie_behavior = "all"
  }
  headers_config {
    header_behavior = "whitelist"
    headers {
      items = ["Origin", "Sec-Fetch-Site", "X-CSRF-Token", "Content-Type", "CloudFront-Viewer-Address"]
    }
  }
  query_strings_config {
    query_string_behavior = "none"
  }
}

resource "aws_cloudfront_distribution" "principal" {
  #checkov:skip=CKV_AWS_174:sem domínio próprio, o certificado padrão não permite fixar TLS 1.2 (ADR-0032)
  #checkov:skip=CKV2_AWS_42:sem domínio próprio nem ACM, por decisão do projeto (ADR-0030)
  #checkov:skip=CKV_AWS_86:requisições registradas no log do WAF, com cookie e token CSRF censurados
  #checkov:skip=CKV_AWS_305:a origem serve a página inicial em /
  #checkov:skip=CKV_AWS_310:origem única
  #checkov:skip=CKV2_AWS_32:CSP, HSTS e demais cabeçalhos vêm da aplicação (helmet); duplicar diverge
  #checkov:skip=CKV2_AWS_47:AWSManagedRulesKnownBadInputsRuleSet (Log4j) está no WAF associado
  enabled         = true
  comment         = "CyberSec Saude"
  is_ipv6_enabled = true
  http_version    = "http2and3"
  price_class     = "PriceClass_All" # inclui as bordas da América do Sul
  web_acl_id      = aws_wafv2_web_acl.cloudfront.arn

  origin {
    origin_id   = "alb"
    domain_name = aws_lb.interno.dns_name

    vpc_origin_config {
      vpc_origin_id            = aws_cloudfront_vpc_origin.alb.id
      origin_keepalive_timeout = 5
      origin_read_timeout      = 30
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origem.result
    }
  }

  default_cache_behavior {
    target_origin_id         = "alb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.sem_cache.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.aplicacao.id
    compress                 = true
  }

  restrictions {
    geo_restriction {
      restriction_type = length(var.paises_permitidos) > 0 ? "whitelist" : "none"
      locations        = var.paises_permitidos
    }
  }

  # Certificado padrão: sem domínio próprio, a AWS não permite fixar TLS 1.2 como mínimo para o
  # navegador (risco aceito no ADR-0032; navegadores atuais negociam TLS 1.3).
  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# --- WAF (us-east-1) -------------------------------------------------------------------------

resource "aws_wafv2_web_acl" "cloudfront" {
  provider    = aws.us_east_1
  name        = "${local.nome}-cloudfront"
  description = "Regras gerenciadas da AWS e limite por IP"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "reputacao-ip"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "reputacao-ip"
      sampled_requests_enabled   = false
    }
  }

  rule {
    name     = "regras-comuns"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
        # O repasse aceita corpo de até 64 KB (ADR-0013); o limite de 8 KB da regra só conta.
        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "regras-comuns"
      sampled_requests_enabled   = false
    }
  }

  rule {
    name     = "entradas-maliciosas"
    priority = 3
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "entradas-maliciosas"
      sampled_requests_enabled   = false
    }
  }

  # Primeira barreira contra flood; o limite por IP e o bloqueio por conta seguem no backend.
  rule {
    name     = "limite-por-ip"
    priority = 4
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit                 = var.waf_limite_por_ip
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "limite-por-ip"
      sampled_requests_enabled   = false
    }
  }

  # Amostras de requisições ficam desligadas: guardariam cookies e cabeçalhos.
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.nome}-cloudfront"
    sampled_requests_enabled   = false
  }
}

# Log do WAF sem cookie nem token CSRF (o nome do grupo precisa começar com aws-waf-logs-).
resource "aws_cloudwatch_log_group" "waf" {
  provider          = aws.us_east_1
  name              = "aws-waf-logs-${local.nome}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.waf.arn
}

# Chave KMS só para o log do WAF: chaves KMS são regionais e o WAF do CloudFront fica em us-east-1.
data "aws_iam_policy_document" "kms_waf" {
  #checkov:skip=CKV_AWS_356:política de chave KMS; resource "*" é a própria chave
  #checkov:skip=CKV_AWS_109:idem
  #checkov:skip=CKV_AWS_111:idem
  statement {
    sid       = "AdministracaoPelaConta"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.atual.partition}:iam::${local.conta}:root"]
    }
  }
  statement {
    sid       = "CloudWatchLogsDaConta"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.us-east-1.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.atual.partition}:logs:us-east-1:${local.conta}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "waf" {
  provider                = aws.us_east_1
  description             = "CyberSec Saude: log do WAF"
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms_waf.json
}

resource "aws_wafv2_web_acl_logging_configuration" "cloudfront" {
  provider                = aws.us_east_1
  resource_arn            = aws_wafv2_web_acl.cloudfront.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
  redacted_fields {
    single_header {
      name = "x-csrf-token"
    }
  }
  redacted_fields {
    single_header {
      name = "x-origin-verify"
    }
  }
  redacted_fields {
    query_string {}
  }
}
