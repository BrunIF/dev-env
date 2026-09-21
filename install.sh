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
TOOL_VERSIONS="${TOOL_VERSIONS:-$HOME/.tool-versions}"
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
RUN_ZSH=false

usage() {
  cat <<EOF
Usage: $0 [--all | джерела...]

Встановлює програмне забезпечення зі списків у config/.

Sources:
  --apt      пакети з config/apt.txt
  --asdf     asdf + плагіни/версії з ~/.tool-versions
  --brew     Homebrew-формули з config/brew.txt
  --nvm      Node.js (версія з config/node-version)
  --github   бінарники з GitHub Releases (config/github.txt)
  --gitlab   бінарники з GitLab Releases (config/gitlab.txt)
  --git      клонування репозиторіїв (config/git.txt)
  --uv       Python CLI-інструменти (config/uv.txt)
  --custom   власні бінарники з custom-bin/ у /usr/local/bin
  --zsh      Oh My Zsh + плагіни та тема (config/zsh-*)
  --all      всі перелічені джерела
  -h, --help показати цю підказку

Приклад: $0 --asdf --nvm --github
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)    RUN_APT=true; RUN_ASDF=true; RUN_BREW=true; RUN_NVM=true
              RUN_GITHUB=true; RUN_GITLAB=true; RUN_GIT=true; RUN_UV=true; RUN_CUSTOM=true; RUN_ZSH=true ;;
    --apt)    RUN_APT=true ;;
    --asdf)   RUN_ASDF=true ;;
    --brew)   RUN_BREW=true ;;
    --nvm)    RUN_NVM=true ;;
    --github) RUN_GITHUB=true ;;
    --gitlab) RUN_GITLAB=true ;;
    --git)    RUN_GIT=true ;;
    --uv)     RUN_UV=true ;;
    --custom) RUN_CUSTOM=true ;;
    --zsh)    RUN_ZSH=true ;;
    -h|--help) usage; exit 0 ;;
    *) error "Невідомий аргумент: $1"; usage; exit 1 ;;
  esac
  shift
done

if ! $RUN_APT && ! $RUN_ASDF && ! $RUN_BREW && ! $RUN_NVM \
   && ! $RUN_GITHUB && ! $RUN_GITLAB && ! $RUN_GIT && ! $RUN_UV && ! $RUN_CUSTOM && ! $RUN_ZSH; then
  error "Вкажіть хоча б одне джерело або --all"
  usage
  exit 1
fi

install_apt() {
  info "Встановлення apt-пакетів з config/apt.txt..."
  sudo apt-get update -y
  local pkgs=()
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -n "${line// }" ] && pkgs+=("$line")
  done < "$CONFIG_DIR/apt.txt"
  sudo apt-get install -y "${pkgs[@]}"
}

install_asdf() {
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

  local tool
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -n "${line// }" ] || continue
    tool="${line%% *}"
    if ! asdf plugin list | grep -qx "$tool"; then
      info "Додаю asdf-плагін $tool..."
      asdf plugin add "$tool" || warn "Не вдалося додати плагін $tool"
    fi
  done < "$TOOL_VERSIONS"

  info "Встановлення asdf-інструментів (може зайняти час)..."
  asdf install || warn "asdf install завершився з помилками, перевірте окремі плагіни"
  asdf reshim
}

install_brew() {
  if ! command -v brew >/dev/null 2>&1; then
    info "Встановлення Homebrew..."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  fi
  local b
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -n "${line// }" ] || continue
    b="$line"
    brew list --formula "$b" >/dev/null 2>&1 || brew install "$b"
  done < "$CONFIG_DIR/brew.txt"
}

install_node() {
  local version
  version="$(grep -v '^#' "$CONFIG_DIR/node-version" | head -1)"
  version="${version// /}"
  export NVM_DIR
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    info "Встановлення nvm..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
  fi
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
  info "Встановлення Node.js $version..."
  nvm install "$version" >/dev/null
  nvm alias default "$version" >/dev/null
  nvm use "$version" >/dev/null
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
  info "Встановлено: /usr/local/bin/$bin"
}

install_links() {
  local bin="$1" links="$2"
  [ -z "$links" ] && return 0
  local l
  while IFS= read -r l; do
    [ -n "$l" ] && sudo ln -sf "$bin" "/usr/local/bin/$l"
  done < <(printf '%s' "$links" | tr ',' '\n')
}

install_github() {
  local line repo pat bin links json tag asset url
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -n "${line// }" ] || continue
    IFS='|' read -r repo pat bin links <<< "$line"
    [ -n "${repo:-}" ] && [ -n "${bin:-}" ] || continue

    if [ -e "/usr/local/bin/$bin" ]; then
      info "Пропускаю $bin (вже встановлено)"
      continue
    fi
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
    info "Встановлення $bin ($tag) з $repo..."
    install_asset "https://github.com/$repo/releases/download/$tag/$asset" "$asset" "$bin"
    install_links "$bin" "$links"
  done < "$CONFIG_DIR/github.txt"
}

install_gitlab() {
  local line repo pat bin proj json tag url name
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -n "${line// }" ] || continue
    IFS='|' read -r repo pat bin <<< "$line"
    [ -n "${repo:-}" ] && [ -n "${bin:-}" ] || continue

    if [ -e "/usr/local/bin/$bin" ]; then
      info "Пропускаю $bin (вже встановлено)"
      continue
    fi
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
    info "Встановлення $bin ($tag) з $repo..."
    install_asset "$url" "$(basename "$url")" "$bin"
  done < "$CONFIG_DIR/gitlab.txt"
}

install_git() {
  local line url dir
  mkdir -p "$HOME/Development"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -n "${line// }" ] || continue
    IFS='|' read -r url dir <<< "$line"
    [ -n "${url:-}" ] && [ -n "${dir:-}" ] || continue
    if [ -d "$HOME/Development/$dir" ]; then
      info "$dir вже існує, пропускаю"
    else
      info "Клонування $url → ~/Development/$dir"
      git clone "$url" "$HOME/Development/$dir"
    fi
  done < "$CONFIG_DIR/git.txt"
}

uv_tool() {
  local pkg="$1"
  if uv tool list 2>/dev/null | grep -q "^$pkg[ @]"; then
    uv tool upgrade "$pkg"
  else
    uv tool install "$pkg"
  fi
}

install_uv() {
  command -v uv >/dev/null 2>&1 || { warn "uv недоступний (встановіть через --asdf або --brew)"; return 0; }
  local pkg
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -n "${line// }" ] || continue
    pkg="$line"
    info "Встановлення $pkg..."
    uv_tool "$pkg"
  done < "$CONFIG_DIR/uv.txt"
}

install_custom() {
  [ -d "$SCRIPT_DIR/custom-bin" ] || return 0
  local count
  count="$(ls -1 "$SCRIPT_DIR/custom-bin" 2>/dev/null | wc -l)"
  [ "$count" -eq 0 ] && return 0
  info "Копіювання custom-bin/ у /usr/local/bin..."
  sudo cp "$SCRIPT_DIR"/custom-bin/* /usr/local/bin/
  sudo chmod +x /usr/local/bin/* 2>/dev/null || true
}

zshrc_add_plugin() {
  local name="$1" rc="$HOME/.zshrc"
  [ -f "$rc" ] || return 0
  grep -q '^plugins=(' "$rc" || return 0
  local found
  found="$(awk -v n="$name" '
    /^plugins=\(/ { inblock=1 }
    inblock && $0 ~ "(^|[[:space:]])" n "([[:space:]]|$)" { found=1 }
    inblock && /^\)/ { exit }
    END { print found+0 }
  ' "$rc")"
  if [ "$found" = "0" ]; then
    awk -v name="  $name" '
      /^plugins=\(/ { inblock=1 }
      inblock && /^\)/ && !inserted { print name; inserted=1 }
      { print }
    ' "$rc" > "$rc.tmp" && mv "$rc.tmp" "$rc"
  fi
}

install_zsh() {
  command -v zsh >/dev/null 2>&1 || warn "zsh не встановлено — виконайте --apt"

  local rc="$HOME/.zshrc"
  if [ ! -d "$HOME/.oh-my-zsh" ]; then
    info "Встановлення Oh My Zsh..."
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || true
  fi

  local theme
  theme="$(grep -v '^#' "$CONFIG_DIR/zsh-theme" | head -1)"
  theme="${theme// /}"
  if [ -n "$theme" ] && grep -q '^ZSH_THEME=' "$rc"; then
    info "Тема zsh: $theme"
    sed -i "s/^ZSH_THEME=.*/ZSH_THEME=\"$theme\"/" "$rc"
  fi

  local ZSH_CUSTOM
  ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

  local line repo plugin
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -n "${line// }" ] || continue
    repo="$line"
    plugin="${repo##*/}"
    if [ ! -d "$ZSH_CUSTOM/plugins/$plugin" ]; then
      info "Встановлення плагіна $plugin..."
      git clone --depth 1 "https://github.com/$repo.git" "$ZSH_CUSTOM/plugins/$plugin"
    fi
    zshrc_add_plugin "$plugin"
  done < "$CONFIG_DIR/zsh-plugins.txt"

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -n "${line// }" ] || continue
    zshrc_add_plugin "$line"
  done < "$CONFIG_DIR/zsh-builtin-plugins.txt"

  if [ "$(command -v zsh)" != "$SHELL" ]; then
    command -v chsh >/dev/null 2>&1 && chsh -s "$(command -v zsh)" 2>/dev/null || warn "Не вдалося змінити shell на zsh (chsh)"
  fi
}

main() {
  info "Початок налаштування системи: $(uname -srm)"
  $RUN_APT    && install_apt
  $RUN_ASDF   && install_asdf
  $RUN_BREW   && install_brew
  $RUN_NVM    && install_node
  $RUN_GITHUB && install_github
  $RUN_GITLAB && install_gitlab
  $RUN_GIT    && install_git
  $RUN_UV     && install_uv
  $RUN_CUSTOM && install_custom
  $RUN_ZSH    && install_zsh
  info "Готово! Перезапустіть шелл або виконайте 'source ~/.zshrc'"
}

main "$@"