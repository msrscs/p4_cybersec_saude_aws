variable "regiao" {
  # us-east-1 por custo (projeto acadêmico, ADR-0033). Com dados de saúde reais, use sa-east-1
  # (LGPD, transferência internacional): troque aqui, em backend.hcl e em bootstrap/.
  description = "Região AWS."
  type        = string
  default     = "us-east-1"
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

variable "rds_retencao_backup_dias" {
  description = "Dias de retenção dos backups automáticos do RDS. O plano gratuito da AWS só aceita 1 (ADR-0034)."
  type        = number
  default     = 7
  validation {
    condition     = var.rds_retencao_backup_dias >= 1 && var.rds_retencao_backup_dias <= 35
    error_message = "Use de 1 a 35 dias; 0 desligaria os backups automáticos."
  }
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
  description = "Tag inicial das imagens; depois o pipeline grava a tag em produção em /cybersec/imagem_tag."
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
  description = "Endpoint OTLP/HTTP fora da VPC. null usa a EC2 do Grafana (observabilidade) ou desliga."
  type        = string
  default     = null
}

# --- Observabilidade (T14, ADR-0037) -----------------------------------------------------------

variable "observabilidade" {
  description = "EC2 do Grafana com Collector, Tempo, Loki e Prometheus; liga o OTLP das tasks."
  type        = bool
  default     = true
}

variable "grafana_tipo_instancia" {
  description = "Tipo da EC2 do Grafana (ARM: as imagens da pilha são multi-arquitetura)."
  type        = string
  default     = "t4g.small"
  validation {
    condition     = can(regex("^[a-z][0-9]+g[a-z]*\\.", var.grafana_tipo_instancia))
    error_message = "Use um tipo ARM (Graviton), ex.: t4g.small: a AMI e o Compose são arm64."
  }
}

variable "compose_versao" {
  description = "Versão do plugin Docker Compose instalado na EC2 do Grafana."
  type        = string
  default     = "v5.8.0"
}

variable "compose_sha256" {
  description = "SHA-256 de docker-compose-linux-aarch64 dessa versão (conferido no boot)."
  type        = string
  default     = "1a9c918b2fb49b9c87f0018c64b5abd0d30715155e98dc939779fbaee6c414d3"
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

# --- CI/CD (T15, ADR-0038) ---------------------------------------------------------------------

variable "github_conectado" {
  description = "true depois de concluir a conexão com o GitHub no console: cria webhook, checks dos PRs e pipeline."
  type        = bool
  default     = false
}

variable "github_repositorio" {
  description = "Repositório (dono/nome) dos PRs e do pipeline."
  type        = string
  default     = "msrscs/p4_cybersec_saude_aws"
}

variable "github_atores_permitidos" {
  description = "IDs numéricos do GitHub cujos PRs disparam o CodeBuild (gh api users/<login> --jq .id)."
  type        = list(string)
  default     = ["205552009"]
  validation {
    condition     = length(var.github_atores_permitidos) > 0 && alltrue([for a in var.github_atores_permitidos : can(regex("^[0-9]+$", a))])
    error_message = "Informe ao menos um ID numérico do GitHub."
  }
}
