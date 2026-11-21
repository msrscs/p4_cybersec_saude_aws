# Bucket do state do Terraform (aplicado uma vez, com state local). Versionado, cifrado, sem
# acesso público e só por TLS. O lock usa o próprio S3 (use_lockfile), sem DynamoDB.
terraform {
  required_version = ">= 1.11.0, < 2.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"
    }
  }
}

variable "regiao" {
  description = "Região do bucket de state (a mesma do ambiente)."
  type        = string
  default     = "us-east-1"
}

provider "aws" {
  region = var.regiao
  default_tags {
    tags = { Projeto = "cybersec-saude", Gerenciado = "terraform-bootstrap" }
  }
}

data "aws_caller_identity" "atual" {}

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_144:replicação entre regiões fora do escopo acadêmico
  #checkov:skip=CKV_AWS_18:acesso ao state auditado pelo CloudTrail
  #checkov:skip=CKV2_AWS_62:sem consumidor de eventos
  bucket = "cybersec-tfstate-${data.aws_caller_identity.atual.account_id}"
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "state" {
  statement {
    sid     = "SoTLS"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
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

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "versoes-antigas"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

output "bucket" {
  value = aws_s3_bucket.state.bucket
}
