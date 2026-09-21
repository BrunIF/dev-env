#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_VERSIONS="${TOOL_VERSIONS:-$HOME/.tool-versions}"
ASDF_DIR="${ASDF_DIR:-$HOME/.asdf}"
NODE_VERSION="${NODE_VERSION:-24.20.0}"
GO_VERSION="${GO_VERSION:-1.24.3}"

RUN_APT=true
RUN_ASDF=true
RUN_BREW=true
RUN_NVM=true
RUN_GO=true
RUN_BIN=true
RUN_PY=true

usage() {
  cat <<EOF
Usage: $0 [options]

Installuje development середовище (Ubuntu/Debian, x86_64/aarch64).

Options:
  --skip-apt     пропустити системні apt-пакети
  --skip-asdf    пропустити asdf + плагіни
  --skip-brew    пропустити Homebrew
  --skip-nvm     пропустити Node.js через nvm
  --skip-go      пропустити Go + go-tools
  --skip-bin     пропустити інструменти у /usr/local/bin (arduino-cli, k3s, custom-bin)
  --skip-py      пропустити Python CLI-інструменти (uv tool)
  -h, --help     показати цю підказку
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-apt)  RUN_APT=false ;;
    --skip-asdf) RUN_ASDF=false ;;
    --skip-brew) RUN_BREW=false ;;
    --skip-nvm)  RUN_NVM=false ;;
    --skip-go)   RUN_GO=false ;;
    --skip-bin)  RUN_BIN=false ;;
    --skip-py)   RUN_PY=false ;;
    -h|--help)   usage; exit 0 ;;
    *) error "Невідомий аргумент: $1"; usage; exit 1 ;;
  esac
  shift
done

install_apt() {
  $RUN_APT || return 0
  info "Встановлення системних пакетів (apt)..."
  sudo apt-get update -y
  sudo apt-get install -y \
    ca-certificates curl wget git jq build-essential unzip \
    zsh tmux htop dnsutils net-tools \
    python3 python3-pip python3-venv
}

install_asdf() {
  $RUN_ASDF || return 0
  if [ ! -f "$ASDF_DIR/asdf.sh" ]; then
    info "Встановлення asdf..."
    git clone --depth 1 https://github.com/asdf-vm/asdf.git "$ASDF_DIR"
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
      [ -f "$rc" ] && ! grep -q "asdf.sh" "$rc" \
        && printf '\n. "%s/asdf.sh"\n' "$ASDF_DIR" >> "$rc"
    done
  fi
  # shellcheck disable=SC1090
  . "$ASDF_DIR/asdf.sh"

  if [ ! -f "$TOOL_VERSIONS" ]; then
    warn "$TOOL_VERSIONS не знайдено, використовую версії з репозиторію"
    TOOL_VERSIONS="$SCRIPT_DIR/.tool-versions"
  fi
  cp "$TOOL_VERSIONS" "$HOME/.tool-versions"

  local plugins=(awscli gcloud k9s kubectl kustomize nerdctl supabase-cli uv xh fx)
  for p in "${plugins[@]}"; do
    if ! asdf plugin list | grep -qx "$p"; then
      info "Додаю asdf-плагін $p..."
      asdf plugin add "$p"
    fi
  done
  info "Встановлення asdf-інструментів (може зайняти час)..."
  asdf install || warn "asdf install завершився з помилками, перевірте окремі плагіни"
  asdf reshim
}

install_brew() {
  $RUN_BREW || return 0
  if ! command -v brew >/dev/null 2>&1; then
    info "Встановлення Homebrew..."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  fi
  local brews=(doggo jless nushell etcd)
  for b in "${brews[@]}"; do
    brew list --formula "$b" >/dev/null 2>&1 || brew install "$b"
  done
}

install_node() {
  $RUN_NVM || return 0
  export NVM_DIR="$HOME/.nvm"
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    info "Встановлення nvm..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
  fi
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
  info "Встановлення Node.js $NODE_VERSION..."
  nvm install "$NODE_VERSION" >/dev/null
  nvm alias default "$NODE_VERSION" >/dev/null
  nvm use "$NODE_VERSION" >/dev/null
  info "Node: $(node --version), npm: $(npm --version)"
}

install_go() {
  $RUN_GO || return 0
  if command -v go >/dev/null 2>&1; then
    info "Go вже встановлено: $(go version)"
  else
    local arch
    case "$(uname -m)" in
      x86_64)  arch="amd64" ;;
      aarch64) arch="arm64" ;;
      *) error "Непідтримувана архітектура: $(uname -m)"; return 1 ;;
    esac
    local tgz="go${GO_VERSION}.linux-${arch}.tar.gz"
    info "Встановлення Go $GO_VERSION..."
    curl -fsSL "https://go.dev/dl/${tgz}" -o "/tmp/${tgz}"
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "/tmp/${tgz}"
    rm -f "/tmp/${tgz}"
  fi
  if command -v go >/dev/null 2>&1; then
    info "Оновлення go-інструментів (gopls, staticcheck)..."
    go install golang.org/x/tools/gopls@latest
    go install honnef.co/go/tools/cmd/staticcheck@latest
  fi
}

install_arduino_cli() {
  [ -e /usr/local/bin/arduino-cli ] && return 0
  local ver arch
  ver="$(curl -fsSL https://api.github.com/repos/arduino/arduino-cli/releases/latest | jq -r .tag_name)"
  case "$(uname -m)" in
    x86_64)  arch="Linux_64bit" ;;
    aarch64) arch="Linux_ARM64" ;;
    *) error "Непідтримувана архітектура: $(uname -m)"; return 1 ;;
  esac
  info "Встановлення arduino-cli $ver..."
  curl -fsSL "https://github.com/arduino/arduino-cli/releases/download/${ver}/arduino-cli_${ver#v}_${arch}.tar.gz" -o /tmp/arduino-cli.tar.gz
  sudo tar -C /usr/local/bin -xzf /tmp/arduino-cli.tar.gz arduino-cli
  rm -f /tmp/arduino-cli.tar.gz
}

install_k3s() {
  [ -e /usr/local/bin/k3s ] && return 0
  info "Встановлення k3s..."
  curl -fsSL "https://github.com/k3s-io/k3s/releases/latest/download/k3s" -o /tmp/k3s
  sudo chmod +x /tmp/k3s
  sudo mv /tmp/k3s /usr/local/bin/k3s
  sudo ln -sf k3s /usr/local/bin/crictl
  sudo ln -sf k3s /usr/local/bin/ctr
}

install_custom_bin() {
  [ -d "$SCRIPT_DIR/custom-bin" ] || return 0
  local count
  count="$(ls -1 "$SCRIPT_DIR/custom-bin" 2>/dev/null | wc -l)"
  [ "$count" -eq 0 ] && return 0
  info "Копіювання власних інструментів з custom-bin/ у /usr/local/bin..."
  sudo cp "$SCRIPT_DIR"/custom-bin/* /usr/local/bin/
  sudo chmod +x /usr/local/bin/* 2>/dev/null || true
}

install_system_bin() {
  $RUN_BIN || return 0
  install_arduino_cli
  install_k3s
  install_custom_bin
}

uv_tool() {
  local pkg="$1"
  if uv tool list 2>/dev/null | grep -q "^$pkg[ @]"; then
    uv tool upgrade "$pkg"
  else
    uv tool install "$pkg"
  fi
}

install_python_tools() {
  $RUN_PY || return 0
  command -v uv >/dev/null 2>&1 || { warn "uv недоступний (asdf), пропускаю Python-інструменти"; return 0; }
  info "Встановлення Python CLI-інструментів через uv..."
  for p in ipython jupyterlab yt-dlp speedtest-cli tinytuya httpx mutagen; do
    uv_tool "$p"
  done
}

main() {
  info "Початок налаштування системи: $(uname -srm)"
  install_apt
  install_asdf
  install_brew
  install_node
  install_go
  install_system_bin
  install_python_tools
  info "Готово! Перезапустіть шелл або виконайте 'source ~/.zshrc'"
}

main "$@"