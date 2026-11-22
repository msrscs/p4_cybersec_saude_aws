#!/usr/bin/env bash
# Instala as ferramentas do CI no CodeBuild (T15, ADR-0038): versões fixas e SHA-256 conferido antes
# de executar qualquer binário baixado. Uso: source buildspecs/ferramentas.sh; instalar uv node ...
# Atualizar: troque a versão e o hash juntos (hash do arquivo publicado pelo próprio projeto).
set -euo pipefail

UV_VERSAO=0.13.6
UV_SHA256=f29c3e94ffabd7e6f3ba521dba169a9b7ec12100bf3257087f0f24f6123f3645
NODE_VERSAO=v26.13.1
NODE_SHA256=5c063e46bab0fbc1c17cc445d7ff129cbdcd0471be6ed83b6ab864f8143bc864
GITLEAKS_VERSAO=8.30.1
GITLEAKS_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
TERRAFORM_VERSAO=1.17.2
TERRAFORM_SHA256=e6f16b2f0b137ee5729caa8c4e79a3bae4ee261acd198a1fcfa8584a6296605b
CHECKOV_VERSAO=3.4.6

FERRAMENTAS=/opt/ferramentas
mkdir -p "$FERRAMENTAS/bin"
export PATH="$FERRAMENTAS/bin:$PATH"

_baixar() { # url destino sha256
  curl -fsSL --proto '=https' --tlsv1.2 -o "$2" "$1"
  echo "$3  $2" | sha256sum -c --quiet - || { echo "hash inválido: $1" >&2; return 1; }
}

_uv() {
  _baixar "https://github.com/astral-sh/uv/releases/download/$UV_VERSAO/uv-x86_64-unknown-linux-gnu.tar.gz" \
    /tmp/uv.tgz "$UV_SHA256"
  tar -xzf /tmp/uv.tgz -C /tmp && install -m 755 /tmp/uv-x86_64-unknown-linux-gnu/uv{,x} "$FERRAMENTAS/bin/"
  # O Python 3.14 vem do python-build-standalone, com hash conferido pelo próprio uv.
  uv python install 3.14
}

_node() {
  _baixar "https://nodejs.org/dist/$NODE_VERSAO/node-$NODE_VERSAO-linux-x64.tar.xz" /tmp/node.txz "$NODE_SHA256"
  tar -xJf /tmp/node.txz -C "$FERRAMENTAS" && ln -sf "$FERRAMENTAS/node-$NODE_VERSAO-linux-x64/bin/"* "$FERRAMENTAS/bin/"
}

_gitleaks() {
  _baixar "https://github.com/gitleaks/gitleaks/releases/download/v$GITLEAKS_VERSAO/gitleaks_${GITLEAKS_VERSAO}_linux_x64.tar.gz" \
    /tmp/gitleaks.tgz "$GITLEAKS_SHA256"
  tar -xzf /tmp/gitleaks.tgz -C "$FERRAMENTAS/bin" gitleaks
}

_terraform() {
  _baixar "https://releases.hashicorp.com/terraform/$TERRAFORM_VERSAO/terraform_${TERRAFORM_VERSAO}_linux_amd64.zip" \
    /tmp/terraform.zip "$TERRAFORM_SHA256"
  unzip -oq /tmp/terraform.zip terraform -d "$FERRAMENTAS/bin"
}

_checkov() { uv tool install --quiet "checkov==$CHECKOV_VERSAO" && export PATH="$HOME/.local/bin:$PATH"; }

instalar() { for f in "$@"; do "_$f"; done; }
