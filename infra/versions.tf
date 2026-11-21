terraform {
  # 1.11+: atributos write-only (senhas geradas sem passar pelo state).
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # Configuração parcial: bucket e chave em backend.hcl (ver backend.hcl.example e README).
  backend "s3" {}
}

provider "aws" {
  region = var.regiao
  default_tags {
    tags = local.tags
  }
}

# WAF de distribuição CloudFront só existe em us-east-1.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = local.tags
  }
}
