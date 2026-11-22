# CI/CD na AWS (T15, ADR-0030 §6, ADR-0038).
#
# - PRs: CodeBuild `cybersec-pr` (lote buildspecs/pr.yml: aplicação + infraestrutura), disparado por
#   webhook só para colaboradores, com status publicado no GitHub. Role só com os próprios logs e a
#   conexão: nenhum segredo, ECR, ECS ou SSM.
# - main: CodePipeline V2 `cybersec`: Fonte -> Verificação -> Imagens -> Aprovação (SNS) ->
#   Migrations -> Deploy backend -> Deploy frontend. Uma role por etapa, cada uma com o mínimo.
#
# Duas fases: a conexão com o GitHub nasce PENDENTE e só fica disponível depois do aceite no console
# (instalação do GitHub App). Até lá (github_conectado = false) não há webhook, credencial nem pipeline.

locals {
  cicd_ativo     = var.github_conectado
  repositorio    = "https://github.com/${var.github_repositorio}.git"
  imagem_build   = "aws/codebuild/standard:7.0"
  projetos_build = toset(["pr", "verificacao", "imagem", "implantacao"])
  arn_logs       = "arn:${data.aws_partition.atual.partition}:logs:${var.regiao}:${local.conta}:log-group"
  # Roles que a implantação passa às tasks que ela registra e executa.
  familias_banco = ["migracao", "bootstrap", "administracao", "limpeza", "verificacao-log"]
}

resource "aws_codestarconnections_connection" "github" {
  name          = "${local.nome}-github"
  provider_type = "GitHub"
}

# --- Tag em produção: o pipeline grava, o Terraform lê (não volta imagem antiga no apply) -------

resource "aws_ssm_parameter" "imagem_tag" {
  #checkov:skip=CKV2_AWS_34:não é segredo (SHA curto do commit, público no GitHub); String sem KMS
  name           = "/${local.nome}/imagem_tag"
  description    = "Tag das imagens em produção (gravada pelo pipeline, lida pelas task definitions)"
  type           = "String"
  insecure_value = var.imagem_tag
  lifecycle {
    ignore_changes = [insecure_value]
  }
}

# --- Logs dos builds ------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "codebuild" {
  for_each          = local.projetos_build
  name              = "/aws/codebuild/${local.nome}-${each.key}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.principal.arn
}

# --- Artefatos do pipeline ------------------------------------------------------------------------

resource "aws_s3_bucket" "artefatos" {
  #checkov:skip=CKV_AWS_144:replicação entre regiões fora do escopo acadêmico
  #checkov:skip=CKV_AWS_18:acesso registrado pelo CloudTrail; artefatos expiram em 30 dias
  #checkov:skip=CKV2_AWS_62:sem consumidor de eventos
  bucket        = "${local.nome}-artefatos-${local.conta}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "artefatos" {
  bucket = aws_s3_bucket.artefatos.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artefatos" {
  bucket = aws_s3_bucket.artefatos.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.principal.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "artefatos" {
  bucket                  = aws_s3_bucket.artefatos.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "artefatos" {
  bucket = aws_s3_bucket.artefatos.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "artefatos" {
  statement {
    sid       = "SoTLS"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.artefatos.arn, "${aws_s3_bucket.artefatos.arn}/*"]
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

resource "aws_s3_bucket_policy" "artefatos" {
  bucket = aws_s3_bucket.artefatos.id
  policy = data.aws_iam_policy_document.artefatos.json
}

resource "aws_s3_bucket_lifecycle_configuration" "artefatos" {
  bucket = aws_s3_bucket.artefatos.id
  rule {
    id     = "expirar"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# --- IAM: uma role por projeto e uma para o pipeline -----------------------------------------------

data "aws_iam_policy_document" "assumir_codebuild" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.conta]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  for_each           = local.projetos_build
  name               = "${local.nome}-codebuild-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.assumir_codebuild.json
}

data "aws_iam_policy_document" "codebuild" {
  for_each = local.projetos_build

  # Todos: só o próprio grupo de log (cifrado pela chave principal).
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.codebuild[each.key].arn}:*"]
  }

  # Lotes (PR e verificação): o próprio projeto inicia os builds do lote.
  dynamic "statement" {
    for_each = contains(["pr", "verificacao"], each.key) ? [1] : []
    content {
      sid       = "Lote"
      actions   = ["codebuild:StartBuild", "codebuild:StopBuild", "codebuild:RetryBuild"]
      resources = ["arn:${data.aws_partition.atual.partition}:codebuild:${var.regiao}:${local.conta}:project/${local.nome}-${each.key}"]
    }
  }

  # PR: clonar e publicar status pelo GitHub App (conexão). Mais nada da conta.
  dynamic "statement" {
    for_each = each.key == "pr" ? [1] : []
    content {
      sid = "Conexao"
      # A conexão tem ARN com o prefixo antigo (codestar-connections): as duas formas são avaliadas.
      actions = flatten([for p in ["codeconnections", "codestar-connections"] : [
        "${p}:GetConnection", "${p}:GetConnectionToken", "${p}:UseConnection"
      ]])
      resources = [aws_codestarconnections_connection.github.arn]
    }
  }

  # Pipeline: ler e gravar os artefatos (cifrados com a chave principal, só via S3).
  dynamic "statement" {
    for_each = each.key == "pr" ? [] : [1]
    content {
      sid       = "Artefatos"
      actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
      resources = ["${aws_s3_bucket.artefatos.arn}/*"]
    }
  }
  dynamic "statement" {
    for_each = each.key == "pr" ? [] : [1]
    content {
      sid       = "ChaveDosArtefatos"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [aws_kms_key.principal.arn]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["s3.${var.regiao}.amazonaws.com"]
      }
    }
  }

  # Imagens: push só nos 3 repositórios.
  dynamic "statement" {
    for_each = each.key == "imagem" ? [1] : []
    content {
      sid       = "LoginEcr"
      actions   = ["ecr:GetAuthorizationToken"]
      resources = ["*"]
    }
  }
  dynamic "statement" {
    for_each = each.key == "imagem" ? [1] : []
    content {
      sid = "PushEcr"
      actions = [
        "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload",
        "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
      ]
      resources = [for r in aws_ecr_repository.modulo : r.arn]
    }
  }

  # Implantação: revisões das tasks de banco e rotinas, a migration e a tag em produção.
  dynamic "statement" {
    for_each = each.key == "implantacao" ? [1] : []
    content {
      sid       = "RevisoesDeTask"
      actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
      resources = ["*"] # sem suporte a recurso nessas ações
    }
  }
  dynamic "statement" {
    for_each = each.key == "implantacao" ? [1] : []
    content {
      sid       = "Migration"
      actions   = ["ecs:RunTask"]
      resources = ["arn:${data.aws_partition.atual.partition}:ecs:${var.regiao}:${local.conta}:task-definition/${local.nome}-migracao:*"]
      condition {
        test     = "ArnEquals"
        variable = "ecs:cluster"
        values   = [aws_ecs_cluster.principal.arn]
      }
    }
  }
  dynamic "statement" {
    for_each = each.key == "implantacao" ? [1] : []
    content {
      sid       = "AcompanharMigration"
      actions   = ["ecs:DescribeTasks"]
      resources = ["arn:${data.aws_partition.atual.partition}:ecs:${var.regiao}:${local.conta}:task/${aws_ecs_cluster.principal.name}/*"]
    }
  }
  dynamic "statement" {
    for_each = each.key == "implantacao" ? [1] : []
    content {
      sid       = "PassarRolesDasTasks"
      actions   = ["iam:PassRole"]
      resources = concat([for f in local.familias_banco : aws_iam_role.execucao[f].arn], [aws_iam_role.administracao.arn])
      condition {
        test     = "StringEquals"
        variable = "iam:PassedToService"
        values   = ["ecs-tasks.amazonaws.com"]
      }
    }
  }
  dynamic "statement" {
    for_each = each.key == "implantacao" ? [1] : []
    content {
      sid       = "ImagemPublicada"
      actions   = ["ecr:DescribeImages"]
      resources = [aws_ecr_repository.modulo["db"].arn, aws_ecr_repository.modulo["backend"].arn]
    }
  }
  dynamic "statement" {
    for_each = each.key == "implantacao" ? [1] : []
    content {
      sid       = "TagEmProducao"
      actions   = ["ssm:PutParameter"]
      resources = [aws_ssm_parameter.imagem_tag.arn]
    }
  }
}

resource "aws_iam_role_policy" "codebuild" {
  for_each = local.projetos_build
  name     = "codebuild"
  role     = aws_iam_role.codebuild[each.key].id
  policy   = data.aws_iam_policy_document.codebuild[each.key].json
}

# --- Projetos CodeBuild ----------------------------------------------------------------------------

locals {
  projetos = {
    verificacao = { buildspec = "buildspecs/pr.yml", privilegiado = true, tamanho = "BUILD_GENERAL1_MEDIUM", lote = true, variaveis = {} }
    imagem = {
      buildspec = "buildspecs/imagem.yml", privilegiado = true, tamanho = "BUILD_GENERAL1_MEDIUM", lote = false
      variaveis = { ECR_REGISTRO = split("/", aws_ecr_repository.modulo["db"].repository_url)[0], PREFIXO = local.nome }
    }
    implantacao = {
      buildspec = "buildspecs/implantacao.yml", privilegiado = false, tamanho = "BUILD_GENERAL1_SMALL", lote = false
      variaveis = {
        CLUSTER          = aws_ecs_cluster.principal.name
        REDE_TASKS_BANCO = "awsvpcConfiguration={subnets=[${join(",", aws_subnet.app[*].id)}],securityGroups=[${aws_security_group.db_admin.id}],assignPublicIp=DISABLED}"
        ECR_REGISTRO     = split("/", aws_ecr_repository.modulo["db"].repository_url)[0]
        PREFIXO          = local.nome
        PARAMETRO_TAG    = aws_ssm_parameter.imagem_tag.name
      }
    }
  }
}

resource "aws_codebuild_project" "pipeline" {
  #checkov:skip=CKV_AWS_316:modo privilegiado para Docker (Postgres do teste e build de imagens); sem segredos
  for_each       = local.projetos
  name           = "${local.nome}-${each.key}"
  description    = "Pipeline ${local.nome}: ${each.key}"
  service_role   = aws_iam_role.codebuild[each.key].arn
  encryption_key = aws_kms_key.principal.arn
  build_timeout  = 45
  queued_timeout = 60

  source {
    type      = "CODEPIPELINE"
    buildspec = each.value.buildspec
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = each.value.tamanho
    image           = local.imagem_build
    type            = "LINUX_CONTAINER"
    privileged_mode = each.value.privilegiado

    dynamic "environment_variable" {
      for_each = each.value.variaveis
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }

  dynamic "build_batch_config" {
    for_each = each.value.lote ? [1] : []
    content {
      service_role    = aws_iam_role.codebuild[each.key].arn
      timeout_in_mins = 45
      restrictions {
        maximum_builds_allowed = 2
        compute_types_allowed  = [each.value.tamanho]
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild[each.key].name
    }
  }

  depends_on = [aws_iam_role_policy.codebuild]
}

# PRs: o clone e o status no GitHub usam a conexão (GitHub App), sem token guardado.
resource "aws_codebuild_source_credential" "github" {
  count       = local.cicd_ativo ? 1 : 0
  auth_type   = "CODECONNECTIONS"
  server_type = "GITHUB"
  token       = aws_codestarconnections_connection.github.arn
}

resource "aws_codebuild_project" "pr" {
  #checkov:skip=CKV_AWS_316:modo privilegiado para Docker; mitigado pelo filtro de ator do webhook e pela role sem acesso à conta
  count          = local.cicd_ativo ? 1 : 0
  name           = "${local.nome}-pr"
  description    = "Checks dos pull requests (aplicação e infraestrutura)"
  service_role   = aws_iam_role.codebuild["pr"].arn
  encryption_key = aws_kms_key.principal.arn
  build_timeout  = 45
  queued_timeout = 60

  source {
    type                = "GITHUB"
    location            = local.repositorio
    buildspec           = "buildspecs/pr.yml"
    git_clone_depth     = 0 # histórico completo para o gitleaks
    report_build_status = true
    auth {
      type     = "CODECONNECTIONS"
      resource = aws_codestarconnections_connection.github.arn
    }
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_MEDIUM"
    image           = local.imagem_build
    type            = "LINUX_CONTAINER"
    privileged_mode = true
  }

  build_batch_config {
    service_role    = aws_iam_role.codebuild["pr"].arn
    timeout_in_mins = 45
    restrictions {
      maximum_builds_allowed = 2
      compute_types_allowed  = ["BUILD_GENERAL1_MEDIUM"]
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild["pr"].name
    }
  }

  depends_on = [aws_iam_role_policy.codebuild, aws_codebuild_source_credential.github]
}

resource "aws_codebuild_webhook" "pr" {
  count        = local.cicd_ativo ? 1 : 0
  project_name = aws_codebuild_project.pr[0].name
  build_type   = "BUILD_BATCH"

  # PR de fork só roda com aprovação por comentário de quem tem escrita no repositório.
  pull_request_build_policy {
    requires_comment_approval = "FORK_PULL_REQUESTS"
    approver_roles            = ["GITHUB_ADMIN", "GITHUB_MAINTAIN", "GITHUB_WRITE"]
  }

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PULL_REQUEST_CREATED, PULL_REQUEST_UPDATED, PULL_REQUEST_REOPENED"
    }
    filter {
      type    = "BASE_REF"
      pattern = "^refs/heads/main$"
    }
    # Só colaboradores: PR de outra pessoa não executa código na conta.
    filter {
      type    = "ACTOR_ACCOUNT_ID"
      pattern = "^(${join("|", var.github_atores_permitidos)})$"
    }
  }
}

# --- Pipeline ---------------------------------------------------------------------------------------

data "aws_iam_policy_document" "assumir_codepipeline" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.conta]
    }
  }
}

resource "aws_iam_role" "pipeline" {
  name               = "${local.nome}-pipeline"
  assume_role_policy = data.aws_iam_policy_document.assumir_codepipeline.json
}

data "aws_iam_policy_document" "pipeline" {
  statement {
    sid       = "Fonte"
    actions   = ["codeconnections:UseConnection", "codestar-connections:UseConnection"]
    resources = [aws_codestarconnections_connection.github.arn]
  }
  statement {
    sid       = "Artefatos"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketVersioning"]
    resources = [aws_s3_bucket.artefatos.arn, "${aws_s3_bucket.artefatos.arn}/*"]
  }
  statement {
    sid       = "ChaveDosArtefatosEAlertas"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.principal.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.regiao}.amazonaws.com", "sns.${var.regiao}.amazonaws.com"]
    }
  }
  statement {
    sid       = "Builds"
    actions   = ["codebuild:BatchGetBuilds", "codebuild:StartBuild", "codebuild:BatchGetBuildBatches", "codebuild:StartBuildBatch"]
    resources = [for p in aws_codebuild_project.pipeline : p.arn]
  }
  statement {
    sid       = "AvisoDeAprovacao"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alertas.arn]
  }
  statement {
    sid       = "DeployEcs"
    actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = [aws_ecs_service.backend.id, aws_ecs_service.frontend.id]
  }
  statement {
    sid       = "RevisoesDoDeploy"
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"] # sem suporte a recurso nessas ações
  }
  statement {
    sid       = "EtiquetarRevisoes"
    actions   = ["ecs:TagResource"]
    resources = [for s in ["backend", "frontend"] : "arn:${data.aws_partition.atual.partition}:ecs:${var.regiao}:${local.conta}:task-definition/${local.nome}-${s}:*"]
  }
  statement {
    sid       = "AcompanharDeploy"
    actions   = ["ecs:DescribeTasks", "ecs:ListTasks"]
    resources = ["arn:${data.aws_partition.atual.partition}:ecs:${var.regiao}:${local.conta}:task/${aws_ecs_cluster.principal.name}/*", "arn:${data.aws_partition.atual.partition}:ecs:${var.regiao}:${local.conta}:container-instance/${aws_ecs_cluster.principal.name}/*"]
  }
  statement {
    sid       = "PassarRolesDoBackendEFrontend"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.execucao["backend"].arn, aws_iam_role.execucao["frontend"].arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "pipeline" {
  name   = "pipeline"
  role   = aws_iam_role.pipeline.id
  policy = data.aws_iam_policy_document.pipeline.json
}

resource "aws_codepipeline" "principal" {
  count          = local.cicd_ativo ? 1 : 0
  name           = local.nome
  pipeline_type  = "V2"
  execution_mode = "QUEUED" # migrations nunca em paralelo
  role_arn       = aws_iam_role.pipeline.arn

  artifact_store {
    type     = "S3"
    location = aws_s3_bucket.artefatos.bucket
    encryption_key {
      id   = aws_kms_key.principal.arn
      type = "KMS"
    }
  }

  trigger {
    provider_type = "CodeStarSourceConnection"
    git_configuration {
      source_action_name = "GitHub"
      push {
        branches {
          includes = ["main"]
        }
      }
    }
  }

  stage {
    name = "Fonte"
    action {
      name             = "GitHub"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["Fonte"]
      configuration = {
        ConnectionArn        = aws_codestarconnections_connection.github.arn
        FullRepositoryId     = var.github_repositorio
        BranchName           = "main"
        OutputArtifactFormat = "CODE_ZIP"
        DetectChanges        = "false" # o gatilho V2 acima dispara
      }
    }
  }

  stage {
    name = "Verificacao"
    action {
      name            = "AplicacaoEInfraestrutura"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["Fonte"]
      configuration = {
        ProjectName  = aws_codebuild_project.pipeline["verificacao"].name
        BatchEnabled = "true"
      }
    }
  }

  stage {
    name = "Imagens"
    action {
      name             = "BuildEPush"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["Fonte"]
      output_artifacts = ["Imagens"]
      configuration = {
        ProjectName = aws_codebuild_project.pipeline["imagem"].name
      }
    }
  }

  stage {
    name = "Aprovacao"
    action {
      name     = "AprovarDeploy"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"
      configuration = {
        NotificationArn = aws_sns_topic.alertas.arn
        CustomData      = "Imagens publicadas. Aprovar aplica as migrations e faz o deploy do backend e do frontend. Confirme que o ambiente não está pausado (infra/scripts/ambiente.sh status)."
      }
    }
  }

  stage {
    name = "Migrations"
    action {
      name            = "TasksDeBancoEMigrations"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["Fonte", "Imagens"]
      configuration = {
        ProjectName   = aws_codebuild_project.pipeline["implantacao"].name
        PrimarySource = "Fonte"
      }
    }
  }

  stage {
    name = "DeployBackend"
    action {
      name            = "Backend"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      version         = "1"
      input_artifacts = ["Imagens"]
      configuration = {
        ClusterName       = aws_ecs_cluster.principal.name
        ServiceName       = aws_ecs_service.backend.name
        FileName          = "imagedefinitions-backend.json"
        DeploymentTimeout = "30"
      }
    }
  }

  stage {
    name = "DeployFrontend"
    action {
      name            = "Frontend"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      version         = "1"
      input_artifacts = ["Imagens"]
      configuration = {
        ClusterName       = aws_ecs_cluster.principal.name
        ServiceName       = aws_ecs_service.frontend.name
        FileName          = "imagedefinitions-frontend.json"
        DeploymentTimeout = "30"
      }
    }
  }

  depends_on = [aws_iam_role_policy.pipeline]
}

# Falha do pipeline -> e-mail (mesmo tópico dos outros alertas).
resource "aws_cloudwatch_event_rule" "pipeline_falhou" {
  count       = local.cicd_ativo ? 1 : 0
  name        = "${local.nome}-pipeline-falhou"
  description = "Execução do pipeline falhou"
  event_pattern = jsonencode({
    source        = ["aws.codepipeline"]
    "detail-type" = ["CodePipeline Pipeline Execution State Change"]
    detail = {
      pipeline = [aws_codepipeline.principal[0].name]
      state    = ["FAILED"]
    }
  })
}

resource "aws_cloudwatch_event_target" "pipeline_falhou" {
  count     = local.cicd_ativo ? 1 : 0
  rule      = aws_cloudwatch_event_rule.pipeline_falhou[0].name
  target_id = "sns"
  arn       = aws_sns_topic.alertas.arn
  input_transformer {
    input_paths = {
      execucao = "$.detail.execution-id"
    }
    input_template = "\"CyberSec Saude: o pipeline falhou (execução <execucao>). Veja no console do CodePipeline.\""
  }
}
