# Segredos no Secrets Manager, cifrados pela chave KMS do ambiente (ADR-0032).
#
# - Senhas das roles do banco: geradas por recurso efêmero e gravadas por atributo write-only.
#   Não passam pelo state nem pelo plano. Para trocar, incremente a versão e reaplique; depois
#   rode a task de bootstrap (que atualiza a senha da role) e force um novo deploy.
# - Chaves da aplicação (KEK, HMAC, checkpoint do log): o Terraform só cria o segredo vazio; o
#   valor é gerado pelo próprio scripts.gerar_chaves via infra/scripts/popular_chaves.sh. A
#   HMAC_KEY e a LOG_CHECKPOINT_KEY nunca podem ser trocadas depois de haver dados.
# - Usuário mestre do RDS: senha gerenciada pelo próprio RDS (ver banco.tf).

locals {
  versao_senhas_banco = 1
}

ephemeral "random_password" "app_db" {
  length  = 40
  special = false
}

ephemeral "random_password" "migrator_db" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "app_db" {
  #checkov:skip=CKV2_AWS_57:rotação por versão (locals.versao_senhas_banco) + bootstrap; sem Lambda
  name                    = "${local.nome}/app-db-password"
  description             = "APP_DB_PASSWORD (role app_user)"
  kms_key_id              = aws_kms_key.principal.arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "app_db" {
  secret_id                = aws_secretsmanager_secret.app_db.id
  secret_string_wo         = ephemeral.random_password.app_db.result
  secret_string_wo_version = local.versao_senhas_banco
}

resource "aws_secretsmanager_secret" "migrator_db" {
  #checkov:skip=CKV2_AWS_57:rotação por versão (locals.versao_senhas_banco) + bootstrap; sem Lambda
  name                    = "${local.nome}/migrator-db-password"
  description             = "MIGRATOR_DB_PASSWORD (role migrator)"
  kms_key_id              = aws_kms_key.principal.arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "migrator_db" {
  secret_id                = aws_secretsmanager_secret.migrator_db.id
  secret_string_wo         = ephemeral.random_password.migrator_db.result
  secret_string_wo_version = local.versao_senhas_banco
}

# JSON com KEK_KEYRING, KEK_ATIVA e HMAC_KEY. Perder este segredo é perder os dados cifrados:
# janela de recuperação máxima e proteção contra destroy.
resource "aws_secretsmanager_secret" "chaves" {
  #checkov:skip=CKV2_AWS_57:HMAC_KEY não pode mudar; KEK só por rotação controlada (ADR-0004)
  name                    = "${local.nome}/chaves-aplicacao"
  description             = "KEK_KEYRING, KEK_ATIVA e HMAC_KEY (ADR-0004)"
  kms_key_id              = aws_kms_key.principal.arn
  recovery_window_in_days = 30
  lifecycle {
    prevent_destroy = true
  }
}

# Só as rotinas recebem (ADR-0010).
resource "aws_secretsmanager_secret" "log_checkpoint" {
  #checkov:skip=CKV2_AWS_57:trocar invalida os checkpoints já gravados (ADR-0010)
  name                    = "${local.nome}/log-checkpoint-key"
  description             = "LOG_CHECKPOINT_KEY (assinatura dos checkpoints do log)"
  kms_key_id              = aws_kms_key.principal.arn
  recovery_window_in_days = 30
  lifecycle {
    prevent_destroy = true
  }
}

# Cabeçalho secreto entre o CloudFront e o ALB (defesa em profundidade, ADR-0030). Precisa
# estar na configuração do CloudFront, então fica no state (cifrado no S3). Rotação:
#   terraform apply -replace=random_password.origem
resource "random_password" "origem" {
  length  = 48
  special = false
}
