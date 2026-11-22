# EC2 do Grafana (T14, ADR-0030 §5, ADR-0037): OTel Collector com redação, Tempo, Loki, Prometheus
# e Grafana, em Docker Compose (infra/observabilidade/).
#
# - Subnet pública com IP público só para saída (SSM, pacotes, imagens). Nenhuma porta aberta para
#   a internet: entra só OTLP 4318, e só dos security groups do frontend e do backend.
# - Acesso ao Grafana só por port forwarding do SSM (infra/scripts/grafana.sh). Sem SSH, sem chave.
# - IMDSv2 com hop limit 1: só o Collector (rede do host) alcança as credenciais da instância.
# - Mudar a pilha ou o user_data recria a VM, e a telemetria guardada (até 7 dias) se perde.

locals {
  observabilidade = var.observabilidade ? { principal = true } : {}
  ip_grafana      = cidrhost(local.cidrs.publica[0], 10)
  otlp_endpoint = (
    var.otlp_endpoint != null ? var.otlp_endpoint
    : var.observabilidade ? "http://${local.ip_grafana}:4318" : null
  )
  grupos_de_log = "/ecs/${local.nome}/"

  # Tudo o que a pilha precisa na EC2, com o conteúdo literal (o template não interpola os arquivos).
  arquivos_observabilidade = {
    for caminho in concat(
      ["compose.yml", "collector.yaml", "tempo.yaml", "loki.yaml", "prometheus.yml"],
      [for f in fileset("${path.module}/observabilidade", "grafana/**") : f],
    ) : caminho => file("${path.module}/observabilidade/${caminho}")
  }
}

data "aws_ssm_parameter" "ami_al2023_arm" {
  count = var.observabilidade ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# --- Senha do admin do Grafana -----------------------------------------------------------------

resource "random_password" "grafana" {
  count   = var.observabilidade ? 1 : 0
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "grafana" {
  #checkov:skip=CKV2_AWS_57:senha de um admin local; troca por versão (taint) e recriação da VM
  count                   = var.observabilidade ? 1 : 0
  name                    = "${local.nome}/grafana-admin"
  description             = "Senha do admin do Grafana (T14)"
  kms_key_id              = aws_kms_key.principal.arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "grafana" {
  count         = var.observabilidade ? 1 : 0
  secret_id     = aws_secretsmanager_secret.grafana[0].id
  secret_string = random_password.grafana[0].result
}

# --- IAM: SSM, a própria senha e leitura dos logs do ECS ---------------------------------------

data "aws_iam_policy_document" "assumir_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "grafana" {
  count              = var.observabilidade ? 1 : 0
  name               = "${local.nome}-grafana"
  assume_role_policy = data.aws_iam_policy_document.assumir_ec2.json
}

resource "aws_iam_role_policy_attachment" "grafana_ssm" {
  count      = var.observabilidade ? 1 : 0
  role       = aws_iam_role.grafana[0].name
  policy_arn = "arn:${data.aws_partition.atual.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "grafana" {
  count = var.observabilidade ? 1 : 0
  statement {
    sid       = "SenhaDoGrafana"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.grafana[0].arn]
  }
  statement {
    sid       = "DecifrarSoPeloSecretsManager"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.principal.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.regiao}.amazonaws.com"]
    }
  }
  statement {
    sid       = "ListarGruposDeLog"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["arn:${data.aws_partition.atual.partition}:logs:${var.regiao}:${local.conta}:log-group:*"]
  }
  statement {
    sid     = "LerLogsDoEcs"
    actions = ["logs:DescribeLogStreams", "logs:FilterLogEvents", "logs:GetLogEvents"]
    resources = [
      "arn:${data.aws_partition.atual.partition}:logs:${var.regiao}:${local.conta}:log-group:${local.grupos_de_log}*",
      "arn:${data.aws_partition.atual.partition}:logs:${var.regiao}:${local.conta}:log-group:${local.grupos_de_log}*:*",
    ]
  }
}

resource "aws_iam_role_policy" "grafana" {
  count  = var.observabilidade ? 1 : 0
  name   = "grafana"
  role   = aws_iam_role.grafana[0].id
  policy = data.aws_iam_policy_document.grafana[0].json
}

resource "aws_iam_instance_profile" "grafana" {
  count = var.observabilidade ? 1 : 0
  name  = "${local.nome}-grafana"
  role  = aws_iam_role.grafana[0].name
}

# --- Security group: entra só OTLP das tasks; sai só HTTPS --------------------------------------

resource "aws_security_group" "grafana" {
  #checkov:skip=CKV2_AWS_5:anexado à aws_instance.grafana
  count       = var.observabilidade ? 1 : 0
  name        = "${local.nome}-grafana"
  description = "EC2 do Grafana: so OTLP das tasks entra"
  vpc_id      = aws_vpc.principal.id
}

locals {
  sg_com_telemetria = var.observabilidade ? {
    frontend = aws_security_group.frontend.id
    backend  = aws_security_group.backend.id
  } : {}
}

resource "aws_vpc_security_group_ingress_rule" "grafana_otlp" {
  for_each                     = local.sg_com_telemetria
  security_group_id            = aws_security_group.grafana[0].id
  description                  = "OTLP/HTTP de ${each.key}"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 4318
  to_port                      = 4318
}

resource "aws_vpc_security_group_egress_rule" "otlp" {
  for_each                     = local.sg_com_telemetria
  security_group_id            = each.value
  description                  = "OTLP/HTTP para o Collector (EC2 do Grafana)"
  referenced_security_group_id = aws_security_group.grafana[0].id
  ip_protocol                  = "tcp"
  from_port                    = 4318
  to_port                      = 4318
}

resource "aws_vpc_security_group_egress_rule" "grafana_https" {
  count             = var.observabilidade ? 1 : 0
  security_group_id = aws_security_group.grafana[0].id
  description       = "HTTPS para SSM, CloudWatch, Secrets Manager, pacotes e imagens"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# --- Instância ---------------------------------------------------------------------------------

resource "aws_instance" "grafana" {
  #checkov:skip=CKV_AWS_88:IP público só para saída (subnet pública, ADR-0030); o SG não abre entrada da internet
  #checkov:skip=CKV_AWS_126:monitoramento detalhado fora do escopo (custo); métricas básicas bastam
  count                       = var.observabilidade ? 1 : 0
  ami                         = data.aws_ssm_parameter.ami_al2023_arm[0].insecure_value
  instance_type               = var.grafana_tipo_instancia
  subnet_id                   = aws_subnet.publica[0].id
  private_ip                  = local.ip_grafana
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.grafana[0].id]
  iam_instance_profile        = aws_iam_instance_profile.grafana[0].name
  ebs_optimized               = true
  monitoring                  = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    kms_key_id            = aws_kms_key.principal.arn
    delete_on_termination = true
  }

  user_data_base64 = base64gzip(templatefile("${path.module}/observabilidade/user_data.sh.tftpl", {
    arquivos        = local.arquivos_observabilidade
    ip_privado      = local.ip_grafana
    regiao          = var.regiao
    grupos_de_log   = local.grupos_de_log
    segredo_grafana = aws_secretsmanager_secret.grafana[0].name
    compose_versao  = var.compose_versao
    compose_sha256  = var.compose_sha256
  }))
  user_data_replace_on_change = true

  tags = { Name = "${local.nome}-grafana" }

  lifecycle {
    # AMI nova sai a cada poucas semanas: não recriar a VM por isso (atualizações pelo dnf).
    ignore_changes = [ami]
  }

  depends_on = [aws_secretsmanager_secret_version.grafana, aws_iam_role_policy.grafana]
}
