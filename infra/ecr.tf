# Um repositório por módulo (ADR-0029). Tags imutáveis: a tag do commit sempre aponta para a
# mesma imagem. Scan na entrada e cifrado com KMS.

locals {
  repositorios = toset(["frontend", "backend", "db"])
}

resource "aws_ecr_repository" "modulo" {
  for_each             = local.repositorios
  name                 = "${local.nome}/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.principal.arn
  }
}

resource "aws_ecr_lifecycle_policy" "modulo" {
  for_each   = aws_ecr_repository.modulo
  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Imagens sem tag somem em 7 dias"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 7 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Guarda as 30 imagens mais recentes (rollback)"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 30 }
        action       = { type = "expire" }
      },
    ]
  })
}
