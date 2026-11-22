# cybersec-vpc em 2 AZs e 4 camadas (ADR-0030):
#   publica: NAT e EC2 do Grafana (T14)  -> IGW
#   borda:   ALB interno                  -> NAT
#   app:     tasks do ECS                 -> NAT
#   dados:   RDS                          -> sem rota para fora da VPC

resource "aws_vpc" "principal" {
  cidr_block           = var.cidr_vpc
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "cybersec-vpc" }
}

# O security group padrão fica sem regra nenhuma: nada usa, nada passa.
resource "aws_default_security_group" "padrao" {
  vpc_id = aws_vpc.principal.id
  tags   = { Name = "${local.nome}-padrao-sem-regras" }
}

resource "aws_internet_gateway" "principal" {
  vpc_id = aws_vpc.principal.id
  tags   = { Name = "${local.nome}-igw" }
}

resource "aws_subnet" "publica" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.principal.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.cidrs.publica[count.index]
  # IP público só quando pedido explicitamente (NAT tem EIP; EC2 do Grafana, observabilidade.tf).
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.nome}-publica-${local.azs[count.index]}", Camada = "publica" }
}

resource "aws_subnet" "borda" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.principal.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.cidrs.borda[count.index]
  tags              = { Name = "${local.nome}-borda-${local.azs[count.index]}", Camada = "borda" }
}

resource "aws_subnet" "app" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.principal.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.cidrs.app[count.index]
  tags              = { Name = "${local.nome}-app-${local.azs[count.index]}", Camada = "app" }
}

resource "aws_subnet" "dados" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.principal.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.cidrs.dados[count.index]
  tags              = { Name = "${local.nome}-dados-${local.azs[count.index]}", Camada = "dados" }
}

# --- Saída para a internet -----------------------------------------------------------------

resource "aws_eip" "nat" {
  count  = var.nat_por_az ? length(local.azs) : 1
  domain = "vpc"
  tags   = { Name = "${local.nome}-nat-${count.index}" }
}

resource "aws_nat_gateway" "principal" {
  count         = length(aws_eip.nat)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.publica[count.index].id
  tags          = { Name = "${local.nome}-nat-${count.index}" }
  depends_on    = [aws_internet_gateway.principal]
}

resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.principal.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.principal.id
  }
  tags = { Name = "${local.nome}-publica" }
}

resource "aws_route_table_association" "publica" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.publica[count.index].id
  route_table_id = aws_route_table.publica.id
}

# Uma tabela por AZ: com nat_por_az, cada AZ sai pelo próprio NAT.
resource "aws_route_table" "privada" {
  count  = length(local.azs)
  vpc_id = aws_vpc.principal.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.principal[var.nat_por_az ? count.index : 0].id
  }
  tags = { Name = "${local.nome}-privada-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "borda" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.borda[count.index].id
  route_table_id = aws_route_table.privada[count.index].id
}

resource "aws_route_table_association" "app" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.privada[count.index].id
}

# Dados: só a rota local da VPC.
resource "aws_route_table" "dados" {
  vpc_id = aws_vpc.principal.id
  tags   = { Name = "${local.nome}-dados" }
}

resource "aws_route_table_association" "dados" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.dados[count.index].id
  route_table_id = aws_route_table.dados.id
}

# Endpoint de gateway do S3 (gratuito): as camadas das imagens do ECR não passam pelo NAT.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.principal.id
  service_name      = "com.amazonaws.${var.regiao}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.privada[*].id
  tags              = { Name = "${local.nome}-s3" }
}

# --- VPC Flow Logs ------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/vpc/${local.nome}/flow-logs"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.principal.arn
}

data "aws_iam_policy_document" "flow_logs_assumir" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.conta]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${local.nome}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assumir.json
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "gravar-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}

resource "aws_flow_log" "vpc" {
  vpc_id          = aws_vpc.principal.id
  traffic_type    = "ALL"
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn    = aws_iam_role.flow_logs.arn
}
