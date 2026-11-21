# Chave KMS do ambiente: RDS, segredos, ECR, logs do CloudWatch e SNS. Rotação anual automática.
# A KEK da aplicação continua no Secrets Manager (cifrada por esta chave), separada dos dados.

# Política de chave: "*" em resource significa a própria chave.
data "aws_iam_policy_document" "kms" {
  #checkov:skip=CKV_AWS_356:política de chave KMS; resource "*" é a própria chave
  #checkov:skip=CKV_AWS_109:idem, administração pela conta (padrão da AWS)
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
    sid = "CloudWatchLogsDaConta"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${var.regiao}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.atual.partition}:logs:${var.regiao}:${local.conta}:log-group:*"]
    }
  }

  # O EventBridge publica alertas no tópico SNS cifrado.
  statement {
    sid       = "EventBridgeParaSns"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.conta]
    }
  }
}

resource "aws_kms_key" "principal" {
  description             = "CyberSec Saude: RDS, segredos, ECR, logs e alertas"
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "principal" {
  name          = "alias/${local.nome}"
  target_key_id = aws_kms_key.principal.key_id
}
