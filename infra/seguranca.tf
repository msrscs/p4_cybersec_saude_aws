# Security groups em cadeia, cada um aceitando só a origem anterior (ADR-0029, ADR-0030):
#   CloudFront (VPC Origin) -> ALB:80 -> frontend:3000 -> backend:8000 -> RDS:5432
# O Terraform remove a regra de saída "liberar tudo" que a AWS cria por padrão; toda saída é
# declarada abaixo. 443 para fora é necessária para ECR, Secrets Manager, CloudWatch e SSM (NAT).

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "${local.nome}-alb"
  description = "ALB interno: so o CloudFront (VPC Origin) entra"
  vpc_id      = aws_vpc.principal.id
}

resource "aws_security_group" "frontend" {
  name        = "${local.nome}-frontend"
  description = "Tasks do frontend: so o ALB entra"
  vpc_id      = aws_vpc.principal.id
}

resource "aws_security_group" "backend" {
  name        = "${local.nome}-backend"
  description = "Tasks do backend: so o frontend entra"
  vpc_id      = aws_vpc.principal.id
}

resource "aws_security_group" "tarefas" {
  #checkov:skip=CKV2_AWS_5:usado pelo Scheduler (rotinas.tf)
  name        = "${local.nome}-tarefas"
  description = "Rotinas do Scheduler: nada entra"
  vpc_id      = aws_vpc.principal.id
}

resource "aws_security_group" "db_admin" {
  #checkov:skip=CKV2_AWS_5:usado por aws ecs run-task (migracao, bootstrap, administracao)
  name        = "${local.nome}-db-admin"
  description = "Migrations, bootstrap e administracao: nada entra"
  vpc_id      = aws_vpc.principal.id
}

resource "aws_security_group" "rds" {
  name        = "${local.nome}-rds"
  description = "RDS: so backend, rotinas e tasks de banco entram"
  vpc_id      = aws_vpc.principal.id
}

# --- ALB ------------------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "alb_cloudfront" {
  #checkov:skip=CKV_AWS_260:origem é o prefix list do CloudFront, não 0.0.0.0/0
  security_group_id = aws_security_group.alb.id
  description       = "CloudFront VPC Origin"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_frontend" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Alvos do frontend"
  referenced_security_group_id = aws_security_group.frontend.id
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
}

# --- Frontend -------------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "frontend_alb" {
  security_group_id            = aws_security_group.frontend.id
  description                  = "ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
}

resource "aws_vpc_security_group_egress_rule" "frontend_backend" {
  security_group_id            = aws_security_group.frontend.id
  description                  = "API (Service Connect)"
  referenced_security_group_id = aws_security_group.backend.id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}

# --- Backend --------------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "backend_frontend" {
  security_group_id            = aws_security_group.backend.id
  description                  = "Frontend (Service Connect)"
  referenced_security_group_id = aws_security_group.frontend.id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}

# --- Saídas comuns: banco e serviços da AWS ---------------------------------------------------

locals {
  sg_com_banco = { backend = aws_security_group.backend.id, tarefas = aws_security_group.tarefas.id, db_admin = aws_security_group.db_admin.id }
  sg_com_saida = merge(local.sg_com_banco, { frontend = aws_security_group.frontend.id })
}

resource "aws_vpc_security_group_egress_rule" "banco" {
  for_each                     = local.sg_com_banco
  security_group_id            = each.value
  description                  = "PostgreSQL (RDS)"
  referenced_security_group_id = aws_security_group.rds.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "rds" {
  for_each                     = local.sg_com_banco
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL de ${each.key}"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "https_aws" {
  for_each          = local.sg_com_saida
  security_group_id = each.value
  description       = "HTTPS para ECR, Secrets Manager, CloudWatch e SSM (via NAT)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# A saída OTLP (4318) para o Collector é criada na T14, referenciando o SG da EC2 do Grafana.
