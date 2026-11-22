output "url" {
  description = "Endereço público do CyberSec Saúde."
  value       = "https://${aws_cloudfront_distribution.principal.domain_name}"
}

output "regiao" {
  value = var.regiao
}

output "ecr" {
  description = "Repositórios das imagens (docker push <repo>:<tag>)."
  value       = local.url_repo
}

output "cluster" {
  value = aws_ecs_cluster.principal.name
}

output "rds_endpoint" {
  value = aws_db_instance.principal.address
}

output "segredos" {
  description = "Segredos a popular com infra/scripts/popular_chaves.sh."
  value = {
    chaves         = aws_secretsmanager_secret.chaves.name
    log_checkpoint = aws_secretsmanager_secret.log_checkpoint.name
  }
}

output "sns_alertas" {
  value = aws_sns_topic.alertas.arn
}

# Rede para `aws ecs run-task` das tasks avulsas (bootstrap, migracao, administracao).
output "rede_tasks_banco" {
  value = "awsvpcConfiguration={subnets=[${join(",", aws_subnet.app[*].id)}],securityGroups=[${aws_security_group.db_admin.id}],assignPublicIp=DISABLED}"
}

output "grafana_instancia" {
  description = "EC2 do Grafana (T14). Acesso: infra/scripts/grafana.sh."
  value       = var.observabilidade ? aws_instance.grafana[0].id : null
}

output "otlp_endpoint" {
  description = "Endpoint OTLP/HTTP que as tasks recebem (null: telemetria desligada)."
  value       = local.otlp_endpoint
}
