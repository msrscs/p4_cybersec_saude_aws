"""Configuração da aplicação, lida exclusivamente de variáveis de ambiente."""

from functools import cached_property, lru_cache
from typing import Literal, Self
from urllib.parse import urlsplit

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy import URL

from app.core.crypto import Keyring, carregar_keyring, decodificar_chave
from app.core.db_url import APP_DB_ROLE, build_database_url, parametros_tls
from app.core.senha import ROUNDS_MINIMO_PRODUCAO


class Settings(BaseSettings):
    # hide_input_in_errors: erros de validação não podem ecoar segredos (input_value).
    model_config = SettingsConfigDict(
        env_file=None, extra="ignore", frozen=True, hide_input_in_errors=True
    )

    environment: Literal["dev", "test", "prod"] = "dev"
    postgres_db: str
    app_db_password: SecretStr
    db_host: str = "localhost"
    db_port: int = 5433
    # TLS até o Postgres (ADR-0013). Produção só aceita verify-full.
    db_sslmode: Literal["verify-full", "require", "disable"] = "verify-full"
    db_sslrootcert: str | None = None

    # Chaves de criptografia (ADR-0004). Nunca ficam no banco.
    kek_keyring: SecretStr
    kek_ativa: int
    hmac_key: SecretStr
    # Assina os checkpoints da cadeia do log (ADR-0010). Só o script de verificação usa;
    # a API não precisa dela e o container do backend não a recebe.
    log_checkpoint_key: SecretStr | None = None

    # Limite de requisições por IP (ADR-0013). Só pode ser desligado fora de produção.
    limite_requisicoes_ativo: bool = True

    # Custo do bcrypt (ADR-0003). Abaixo de 12 só é aceito em ENVIRONMENT=test.
    bcrypt_rounds: int = 12

    # Telemetria (ADR-0031). Sem endpoint, nada é exportado. Ex.: http://10.0.0.10:4318
    otel_exporter_otlp_endpoint: str | None = None
    otel_service_name: str = "cybersec-backend"
    # Fração dos traces iniciados aqui; os que vêm do frontend seguem a decisão dele.
    otel_traces_sampler_arg: float = Field(default=1.0, ge=0.0, le=1.0)

    @model_validator(mode="after")
    def _validar_chaves(self) -> Self:
        # Falha na inicialização se alguma chave for inválida; mensagens sem material de chave.
        _ = self.keyring
        # Fora do `if`: a API não recebe LOG_CHECKPOINT_KEY e ainda assim precisa falhar aqui.
        chave_hmac = self.chave_hmac
        if self.chave_checkpoint is not None and self.chave_checkpoint == chave_hmac:
            raise ValueError("LOG_CHECKPOINT_KEY deve ser diferente de HMAC_KEY.")
        return self

    @model_validator(mode="after")
    def _validar_tls_banco(self) -> Self:
        _ = self.tls_banco
        if self.is_production and self.db_sslmode != "verify-full":
            raise ValueError("Em produção, DB_SSLMODE deve ser verify-full.")
        if self.is_production and not self.limite_requisicoes_ativo:
            raise ValueError("Em produção, o limite de requisições não pode ser desligado.")
        return self

    @model_validator(mode="after")
    def _validar_bcrypt(self) -> Self:
        minimo = 4 if self.environment == "test" else ROUNDS_MINIMO_PRODUCAO
        if not minimo <= self.bcrypt_rounds <= 16:
            raise ValueError(f"BCRYPT_ROUNDS deve estar entre {minimo} e 16.")
        return self

    @field_validator("otel_exporter_otlp_endpoint")
    @classmethod
    def _validar_endpoint_otlp(cls, valor: str | None) -> str | None:
        if valor is None:
            return None
        url = urlsplit(valor)
        # Só esquema + host + porta: credencial na URL iria parar em log de erro do exportador.
        if (
            url.scheme not in {"http", "https"}
            or not url.hostname
            or url.username
            or url.password
            or url.path not in {"", "/"}
            or url.query
            or url.fragment
        ):
            raise ValueError("OTEL_EXPORTER_OTLP_ENDPOINT deve ser só esquema, host e porta.")
        return valor.rstrip("/")

    @property
    def is_production(self) -> bool:
        return self.environment == "prod"

    @property
    def database_url(self) -> URL:
        return build_database_url(
            user=APP_DB_ROLE,
            password=self.app_db_password.get_secret_value(),
            database=self.postgres_db,
            host=self.db_host,
            port=self.db_port,
            tls=self.tls_banco,
        )

    @cached_property
    def tls_banco(self) -> dict[str, str]:
        return parametros_tls(self.db_sslmode, self.db_sslrootcert)

    @cached_property
    def keyring(self) -> Keyring:
        return carregar_keyring(self.kek_keyring.get_secret_value(), self.kek_ativa)

    @cached_property
    def chave_hmac(self) -> bytes:
        return decodificar_chave(self.hmac_key.get_secret_value())

    @cached_property
    def chave_checkpoint(self) -> bytes | None:
        if self.log_checkpoint_key is None:
            return None
        return decodificar_chave(self.log_checkpoint_key.get_secret_value())


@lru_cache
def get_settings() -> Settings:
    return Settings()
