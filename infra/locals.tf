data "aws_caller_identity" "atual" {}
data "aws_partition" "atual" {}
data "aws_region" "atual" {}

data "aws_availability_zones" "disponiveis" {
  #checkov:skip=CKV_AWS_394:usa só as duas primeiras AZs (slice), estáveis na região
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  nome  = "cybersec"
  conta = data.aws_caller_identity.atual.account_id
  tags = {
    Projeto    = "cybersec-saude"
    Ambiente   = "prod"
    Gerenciado = "terraform"
  }

  azs = slice(data.aws_availability_zones.disponiveis.names, 0, 2)

  # /24 por AZ em cada camada (ADR-0030).
  cidrs = {
    publica = [for i, _ in local.azs : cidrsubnet(var.cidr_vpc, 8, i)]
    borda   = [for i, _ in local.azs : cidrsubnet(var.cidr_vpc, 8, 10 + i)]
    app     = [for i, _ in local.azs : cidrsubnet(var.cidr_vpc, 8, 20 + i)]
    dados   = [for i, _ in local.azs : cidrsubnet(var.cidr_vpc, 8, 30 + i)]
  }

  # CA do RDS embutida nas imagens do backend e do db (ADR-0029).
  ca_rds = "/etc/ssl/rds/global-bundle.pem"
}
