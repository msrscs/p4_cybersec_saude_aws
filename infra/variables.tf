variable "regiao" {
  description = "Região AWS. São Paulo mantém os dados de saúde no Brasil (LGPD, ADR-0032)."
  type        = string
  default     = "sa-east-1"
}

variable "cidr_vpc" {
  description = "CIDR da cybersec-vpc. Cada camada usa /24 por AZ."
  type        = string
  default     = "10.20.0.0/16"
}

variable "nat_por_az" {
  description = "true: um NAT Gateway por AZ (produção). false: NAT único (acadêmico, ADR-0030)."
  type        = bool
  default     = false
}

variable "protecao_exclusao" {
  description = "Proteção contra exclusão do RDS e do ALB."
  type        = bool
  default     = true
}

# --- Banco -------------------------------------------------------------------------------

variable "rds_versao" {
  description = "Versão do PostgreSQL no RDS (só a major: o RDS escolhe a minor padrão)."
  type        = string
  default     = "18"
}

variable "rds_classe" {
  description = "Classe da instância cybersec-db."
  type        = string
  default     = "db.t4g.small"
}

variable "rds_multi_az" {
  description = "Instância standby em outra AZ. false por custo (ADR-0030)."
  type        = bool
  default     = false
}

variable "rds_armazenamento_gb" {
  description = "Armazenamento inicial (gp3); cresce sozinho até 5x."
  type        = number
  default     = 20
}

variable "nome_banco" {
  description = "Nome do banco (POSTGRES_DB)."
  type        = string
  default     = "cybersec_saude"
}

# --- Aplicação ---------------------------------------------------------------------------

variable "imagem_tag" {
  description = "Tag das imagens no ECR (o pipeline usa o SHA do commit)."
  type        = string
  default     = "inicial"
}

variable "arquitetura" {
  description = "Arquitetura das tasks e das imagens: X86_64 ou ARM64."
  type        = string
  default     = "X86_64"
  validation {
    condition     = contains(["X86_64", "ARM64"], var.arquitetura)
    error_message = "Use X86_64 ou ARM64."
  }
}

variable "tasks_minimas" {
  description = "Tasks por serviço (frontend e backend): uma por AZ no mínimo."
  type        = number
  default     = 2
  validation {
    condition     = var.tasks_minimas >= 2
    error_message = "Mínimo de 2 tasks por serviço (uma por AZ)."
  }
}

variable "tasks_maximas" {
  description = "Limite do auto scaling por serviço."
  type        = number
  default     = 4
}

variable "frontend_cpu" {
  type    = number
  default = 256
}

variable "frontend_memoria" {
  type    = number
  default = 512
}

variable "backend_cpu" {
  description = "CPU do backend: o bcrypt (custo 12) pesa no login."
  type        = number
  default     = 512
}

variable "backend_memoria" {
  type    = number
  default = 1024
}

variable "otlp_endpoint" {
  description = "Endpoint OTLP/HTTP do Collector (T14), ex.: http://10.20.0.10:4318. null desliga."
  type        = string
  default     = null
}

# --- Borda -------------------------------------------------------------------------------

variable "paises_permitidos" {
  description = "Países com acesso pelo CloudFront (ISO 3166-1). Lista vazia libera todos."
  type        = list(string)
  default     = ["BR"]
}

variable "waf_limite_por_ip" {
  description = "Requisições por IP a cada 5 minutos antes do bloqueio no WAF."
  type        = number
  default     = 1000
}

variable "email_alertas" {
  description = "E-mail que recebe alertas (rotinas com falha). null: sem assinatura."
  type        = string
  default     = null
}
