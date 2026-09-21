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
CONFIG_DIR="$SCRIPT_DIR/config"
ASDF_DIR="${ASDF_DIR:-$HOME/.asdf}"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

RUN_APT=false
RUN_ASDF=false
RUN_BREW=false
RUN_NVM=false
RUN_GITHUB=false
RUN_GITLAB=false
RUN_GIT=false
RUN_UV=false
RUN_CUSTOM=false

usage() {
  cat <<EOF
Usage: $0 [--all | джерела...]

Оновлює встановлені інструменти. Без аргументів оновлює все, що знайдено.

Sources:
  --apt      sudo apt-get update && upgrade
  --asdf     asdf update + plugin update + apply ~/.tool-versions
  --brew     brew update && upgrade
  --nvm      Node.js (версія з config/node-version) + npm -g
  --github   переступання останніх релізів (config/github.txt)
  --gitlab   переступання останніх релізів (config/gitlab.txt)
  --git      git pull у клонованих репозиторіях (config/git.txt)
  --uv       uv tool upgrade --all
  --custom   перекопіювати custom-bin/ у /usr/local/bin
  --all      оновити всі джерела
  -h, --help показати цю підказку
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)    RUN_APT=true; RUN_ASDF=true; RUN_BREW=true; RUN_NVM=true
              RUN_GITHUB=true; RUN_GITLAB=true; RUN_GIT=true; RUN_UV=true; RUN_CUSTOM=true ;;
    --apt)    RUN_APT=true ;;
    --asdf)   RUN_ASDF=true ;;
    --brew)   RUN_BREW=true ;;
    --nvm)    RUN_NVM=true ;;
    --github) RUN_GITHUB=true ;;
    --gitlab) RUN_GITLAB=true ;;
    --git)    RUN_GIT=true ;;
    --uv)     RUN_UV=true ;;
    --custom) RUN_CUSTOM=true ;;
    -h|--help) usage; exit 0 ;;
    *) error "Невідомий аргумент: $1"; usage; exit 1 ;;
  esac
  shift
done

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
    info "Застосування версій з ~/.tool-versions..."
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
  local version
  version="$(grep -v '^#' "$CONFIG_DIR/node-version" | head -1)"
  version="${version// /}"
  info "Оновлення Node.js до $version..."
  nvm install "$version" >/dev/null
  nvm alias default "$version" >/dev/null
  nvm use "$version" >/dev/null
  command -v npm >/dev/null 2>&1 && npm update -g 2>/dev/null || true
  info "Node: $(node --version), npm: $(npm --version)"
}

install_asset() {
  local url="$1" name="$2" bin="$3"
  local dl tmpdir binpath
  dl=$(mktemp)
  trap 'rm -rf "$dl" "${tmpdir:-}"' RETURN
  curl -fsSL "$url" -o "$dl"

  case "$name" in
    *.tar.gz|*.tgz|*.tar.xz|*.tar.bz2)
      tmpdir=$(mktemp -d)
      tar -xf "$dl" -C "$tmpdir"
      binpath="$(find "$tmpdir" -type f -name "$bin" | head -1)"
      ;;
    *.zip)
      tmpdir=$(mktemp -d)
      unzip -q "$dl" -d "$tmpdir"
      binpath="$(find "$tmpdir" -type f -name "$bin" | head -1)"
      ;;
    *)
      binpath="$dl"
      ;;
  esac

  if [ -z "${binpath:-}" ]; then
    error "Не знайдено бінарник '$bin' в асеті '$name'"
    return 1
  fi
  sudo install -m 0755 "$binpath" "/usr/local/bin/$bin"
  info "Оновлено: /usr/local/bin/$bin"
}

install_links() {
  local bin="$1" links="$2"
  [ -z "$links" ] && return 0
  local l
  while IFS= read -r l; do
    [ -n "$l" ] && sudo ln -sf "$bin" "/usr/local/bin/$l"
  done < <(printf '%s' "$links" | tr ',' '\n')
}

update_github() {
  local line repo pat bin links json tag asset url
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -n "${line// }" ] || continue
    IFS='|' read -r repo pat bin links <<< "$line"
    [ -n "${repo:-}" ] && [ -n "${bin:-}" ] || continue

    local installed=""
    [ -e "/usr/local/bin/$bin" ] && installed="yes"
    json="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest")" || { warn "Немає доступу до $repo"; continue; }
    tag="$(printf '%s' "$json" | jq -r '.tag_name')"
    asset=""
    while IFS= read -r a; do
      a="${a//[[:space:]]/}"
      [ -n "$a" ] || continue
      case "$a" in
        $pat) asset="$a"; break ;;
      esac
    done < <(printf '%s' "$json" | jq -r '.assets[].name')
    if [ -z "$asset" ]; then
      warn "Не знайдено асета '$pat' для $repo ($tag)"
      continue
    fi
    if [ "$installed" = "yes" ]; then
      info "Оновлення $bin до $tag..."
    else
      info "Встановлення $bin ($tag)..."
    fi
    install_asset "https://github.com/$repo/releases/download/$tag/$asset" "$asset" "$bin"
    install_links "$bin" "$links"
  done < "$CONFIG_DIR/github.txt"
}

update_gitlab() {
  local line repo pat bin proj json tag url
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -n "${line// }" ] || continue
    IFS='|' read -r repo pat bin <<< "$line"
    [ -n "${repo:-}" ] && [ -n "${bin:-}" ] || continue

    proj="${repo//\//%2F}"
    json="$(curl -fsSL "https://gitlab.com/api/v4/projects/$proj/releases/permalink/latest")" || { warn "Немає доступу до $repo"; continue; }
    tag="$(printf '%s' "$json" | jq -r '.tag_name')"
    url=""
    while IFS=$'\t' read -r a_name a_url; do
      case "$a_name" in
        $pat) url="$a_url"; break ;;
      esac
    done < <(printf '%s' "$json" | jq -r '.assets.links[] | [.name,.url] | @tsv')
    if [ -z "$url" ]; then
      warn "Не знайдено асета '$pat' для $repo ($tag)"
      continue
    fi
    info "Оновлення $bin до $tag..."
    install_asset "$url" "$(basename "$url")" "$bin"
  done < "$CONFIG_DIR/gitlab.txt"
}

update_git() {
  mkdir -p "$HOME/Development"
  local line url dir
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -n "${line// }" ] || continue
    IFS='|' read -r url dir <<< "$line"
    [ -n "${url:-}" ] && [ -n "${dir:-}" ] || continue
    if [ -d "$HOME/Development/$dir/.git" ]; then
      info "git pull у ~/Development/$dir..."
      git -C "$HOME/Development/$dir" pull --ff-only || warn "не вдалося оновити $dir"
    elif [ -d "$HOME/Development/$dir" ]; then
      warn "$dir існує, але не є git-репозиторієм, пропускаю"
    else
      info "Клонування $url → ~/Development/$dir"
      git clone "$url" "$HOME/Development/$dir"
    fi
  done < "$CONFIG_DIR/git.txt"
}

update_uv() {
  command -v uv >/dev/null 2>&1 || { warn "uv не знайдено, пропускаю"; return 0; }
  if [ "$(uv tool list 2>/dev/null | wc -l)" -eq 0 ]; then
    warn "Немає встановлених uv-інструментів, пропускаю"
    return 0
  fi
  info "Оновлення uv-інструментів..."
  uv tool upgrade --all
}

update_custom() {
  if [ -d "$SCRIPT_DIR/custom-bin" ] && [ "$(ls -1 "$SCRIPT_DIR/custom-bin" 2>/dev/null | wc -l)" -gt 0 ]; then
    info "Оновлення custom-bin/..."
    sudo cp "$SCRIPT_DIR"/custom-bin/* /usr/local/bin/
    sudo chmod +x /usr/local/bin/* 2>/dev/null || true
  fi
}

main() {
  if ! $RUN_APT && ! $RUN_ASDF && ! $RUN_BREW && ! $RUN_NVM \
     && ! $RUN_GITHUB && ! $RUN_GITLAB && ! $RUN_GIT && ! $RUN_UV && ! $RUN_CUSTOM; then
    RUN_APT=true; RUN_ASDF=true; RUN_BREW=true; RUN_NVM=true
    RUN_GITHUB=true; RUN_GITLAB=true; RUN_GIT=true; RUN_UV=true; RUN_CUSTOM=true
    info "Без аргументів - оновлення всіх джерел"
  fi

  info "Початок оновлення системи: $(uname -srm)"
  $RUN_APT    && update_apt
  $RUN_ASDF   && update_asdf
  $RUN_BREW   && update_brew
  $RUN_NVM    && update_node
  $RUN_GITHUB && update_github
  $RUN_GITLAB && update_gitlab
  $RUN_GIT    && update_git
  $RUN_UV     && update_uv
  $RUN_CUSTOM && update_custom
  info "Готово!"
}

main "$@"