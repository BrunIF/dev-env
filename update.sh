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
ASDF_DIR="${ASDF_DIR:-$HOME/.asdf}"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

update_apt() {
  info "Оновлення apt-пакетів..."
  sudo apt-get update -y
  sudo apt-get upgrade -y
  sudo apt-get autoremove -y
}

update_asdf() {
  [ -f "$ASDF_DIR/asdf.sh" ] || { warn "asdf не знайдено, пропускаю"; return 0; }
  # shellcheck disable=SC1090
  . "$ASDF_DIR/asdf.sh"
  info "Оновлення asdf..."
  asdf update 2>/dev/null || true
  command -v brew >/dev/null 2>&1 && brew upgrade asdf 2>/dev/null || true
  asdf plugin update --all 2>/dev/null || true
  if [ -f "$HOME/.tool-versions" ]; then
    info "Застосування/оновлення версій з ~/.tool-versions..."
    asdf install || warn "asdf install завершився з помилками, перевірте окремі плагіни"
    asdf reshim
  fi
}

update_brew() {
  command -v brew >/dev/null 2>&1 || { warn "brew не знайдено, пропускаю"; return 0; }
  info "Оновлення Homebrew..."
  brew update
  brew upgrade
  brew cleanup --prune=all 2>/dev/null || true
}

update_node() {
  [ -s "$NVM_DIR/nvm.sh" ] || { warn "nvm не знайдено, пропускаю"; return 0; }
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
  info "Оновлення Node.js..."
  local latest
  latest="$(nvm version-remote --lts 2>/dev/null || echo "")"
  if [ -n "$latest" ]; then
    nvm install "$latest" >/dev/null
    nvm alias default "$latest" >/dev/null
    nvm use "$latest" >/dev/null
  fi
  command -v npm >/dev/null 2>&1 && npm update -g 2>/dev/null || true
  info "Node: $(node --version), npm: $(npm --version)"
}

update_go_tools() {
  command -v go >/dev/null 2>&1 || { warn "go не знайдено, пропускаю"; return 0; }
  info "Оновлення go-інструментів..."
  go install golang.org/x/tools/gopls@latest
  go install honnef.co/go/tools/cmd/staticcheck@latest
}

update_arduino_cli() {
  command -v arduino-cli >/dev/null 2>&1 || return 0
  info "Оновлення arduino-cli..."
  arduino-cli update >/dev/null 2>&1 || true
  arduino-cli version
}

update_custom_bin() {
  if [ -d "$SCRIPT_DIR/custom-bin" ] && [ "$(ls -1 "$SCRIPT_DIR/custom-bin" 2>/dev/null | wc -l)" -gt 0 ]; then
    info "Оновлення власних інструментів з custom-bin/..."
    sudo cp "$SCRIPT_DIR"/custom-bin/* /usr/local/bin/
  fi
}

update_python_tools() {
  command -v uv >/dev/null 2>&1 || { warn "uv не знайдено, пропускаю"; return 0; }
  if [ "$(uv tool list 2>/dev/null | wc -l)" -eq 0 ]; then
    warn "Немає встановлених uv-інструментів, пропускаю"
    return 0
  fi
  info "Оновлення Python CLI-інструментів (uv)..."
  for pkg in $(uv tool list 2>/dev/null | awk '{print $1}' | grep -v '^$'); do
    uv tool upgrade "$pkg"
  done
}

update_k3s() {
  [ -e /usr/local/bin/k3s ] || return 0
  info "Оновлення k3s (latest)..."
  curl -fsSL "https://github.com/k3s-io/k3s/releases/latest/download/k3s" -o /tmp/k3s
  sudo chmod +x /tmp/k3s
  sudo mv /tmp/k3s /usr/local/bin/k3s
  /usr/local/bin/k3s --version
}

main() {
  info "Початок оновлення системи: $(uname -srm)"
  update_apt
  update_asdf
  update_brew
  update_node
  update_go_tools
  update_arduino_cli
  update_k3s
  update_custom_bin
  update_python_tools
  info "Готово!"
}

main "$@"