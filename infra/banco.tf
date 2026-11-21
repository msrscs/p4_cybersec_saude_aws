# RDS PostgreSQL 18, instância cybersec-db (ADR-0030). TLS obrigatório, cifrado com KMS, sem
# acesso público, nas subnets de dados (sem rota para fora da VPC).

resource "aws_db_subnet_group" "principal" {
  name        = "${local.nome}-db"
  description = "Subnets privadas de dados (2 AZs)"
  subnet_ids  = aws_subnet.dados[*].id
}

resource "aws_db_parameter_group" "principal" {
  name        = "${local.nome}-postgres${var.rds_versao}"
  family      = "postgres${var.rds_versao}"
  description = "TLS obrigatorio (1.2+) e senhas SCRAM"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name  = "ssl_min_protocol_version"
    value = "TLSv1.2"
  }
  parameter {
    name  = "password_encryption"
    value = "scram-sha-256"
  }
  # Erros não registram os valores dos parâmetros das queries (padrão; fixado aqui).
  parameter {
    name  = "log_parameter_max_length_on_error"
    value = "0"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Grupos de log criados antes do RDS, com KMS e retenção (o RDS os criaria sem ambos).
resource "aws_cloudwatch_log_group" "rds" {
  for_each          = toset(["postgresql", "upgrade"])
  name              = "/aws/rds/instance/${local.nome}-db/${each.key}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.principal.arn
}

resource "aws_db_instance" "principal" {
  #checkov:skip=CKV_AWS_157:Single-AZ por custo; var.rds_multi_az liga (ADR-0030)
  #checkov:skip=CKV_AWS_161:a aplicação autentica por senha SCRAM; IAM auth seria um caminho a mais
  #checkov:skip=CKV_AWS_353:Performance Insights fora do escopo; métricas no CloudWatch/Grafana
  #checkov:skip=CKV_AWS_118:monitoramento avançado fora do escopo acadêmico
  identifier     = "${local.nome}-db"
  engine         = "postgres"
  engine_version = var.rds_versao
  instance_class = var.rds_classe

  db_name  = var.nome_banco
  username = "cs_admin" # não pode ser app_user nem migrator (bootstrap_db recusa)
  # Senha do usuário mestre gerada, guardada e rotacionada pelo RDS no Secrets Manager.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.principal.arn

  allocated_storage     = var.rds_armazenamento_gb
  max_allocated_storage = var.rds_armazenamento_gb * 5
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.principal.arn

  db_subnet_group_name   = aws_db_subnet_group.principal.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.principal.name
  publicly_accessible    = false
  multi_az               = var.rds_multi_az
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  backup_retention_period   = 7
  backup_window             = "05:00-06:00" # 02h-03h em Brasília
  maintenance_window        = "sun:06:30-sun:07:30"
  copy_tags_to_snapshot     = true
  deletion_protection       = var.protecao_exclusao
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.nome}-db-final"
  delete_automated_backups  = false

  auto_minor_version_upgrade      = true
  allow_major_version_upgrade     = false
  apply_immediately               = false
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  depends_on = [aws_cloudwatch_log_group.rds]
}
