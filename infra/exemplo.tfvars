# Copie para terraform.tfvars (fora do git) e ajuste. Todas têm padrão em variables.tf.
email_alertas = "equipe@exemplo.gov.br"

# Produção (custo maior):
# nat_por_az   = true
# rds_multi_az = true

# Conta no plano gratuito da AWS (ADR-0034):
# rds_classe               = "db.t4g.micro"
# rds_retencao_backup_dias = 1

# Depois da T14 (IP privado da EC2 do Grafana):
# otlp_endpoint = "http://10.20.0.10:4318"
