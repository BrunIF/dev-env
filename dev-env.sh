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

MODE=""
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
Usage: $0 {install|update} [--all | джерела...]

Встановлює або оновлює ПЗ зі списків у config/.

  install  встановити (потрібно вказати джерело або --all)
  update   оновити все встановлене (без аргументів - всі джерела)

Sources:
  --apt      пакети з config/apt.txt (install: apt-get install; update: upgrade)
  --asdf     asdf + плагіни/версії з ~/.tool-versions
  --brew     Homebrew-формули з config/brew.txt
  --nvm      Node.js (версія з config/node-version)
  --github   бінарники з GitHub Releases (config/github.txt)
  --gitlab   бінарники з GitLab Releases (config/gitlab.txt)
  --git      клонування/оновлення репозиторіїв (config/git.txt)
  --uv       Python CLI-інструменти (config/uv.txt)
  --custom   власні бінарники з custom-bin/ у /usr/local/bin
  --zsh      Oh My Zsh + плагіни та тема (config/zsh-*)
  --all      всі джерела
  -h, --help показати цю підказку

Приклади:
  $0 install --all
  $0 install --asdf --nvm --github --zsh
  $0 update
  $0 update --github --uv
EOF
}

no_sources_selected() {
  ! $RUN_APT && ! $RUN_ASDF && ! $RUN_BREW && ! $RUN_NVM \
    && ! $RUN_GITHUB && ! $RUN_GITLAB && ! $RUN_GIT && ! $RUN_UV && ! $RUN_CUSTOM && ! $RUN_ZSH
}

set_all() {
  RUN_APT=true; RUN_ASDF=true; RUN_BREW=true; RUN_NVM=true
  RUN_GITHUB=true; RUN_GITLAB=true; RUN_GIT=true; RUN_UV=true
  RUN_CUSTOM=true; RUN_ZSH=true
}

parse_source_flag() {
  case "$1" in
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
    --all)    set_all ;;
    *) return 1 ;;
  esac
  return 0
}

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

update_apt() {
  info "Оновлення apt-пакетів..."
  sudo apt-get update -y
  sudo apt-get upgrade -y
  sudo apt-get autoremove -y
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

update_brew() {
  command -v brew >/dev/null 2>&1 || { warn "brew не знайдено, пропускаю"; return 0; }
  info "Оновлення Homebrew..."
  brew update
  brew upgrade
  brew cleanup --prune=all 2>/dev/null || true
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
  info "/usr/local/bin/$bin: готово"
}

install_links() {
  local bin="$1" links="$2"
  [ -z "$links" ] && return 0
  local l
  while IFS= read -r l; do
    [ -n "$l" ] && sudo ln -sf "$bin" "/usr/local/bin/$l"
  done < <(printf '%s' "$links" | tr ',' '\n')
}

sync_github() {
  local force="$1"
  local line repo pat bin links json tag asset url
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -n "${line// }" ] || continue
    IFS='|' read -r repo pat bin links <<< "$line"
    [ -n "${repo:-}" ] && [ -n "${bin:-}" ] || continue

    if [ "$force" = "false" ] && command -v "$bin" >/dev/null 2>&1; then
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
    info "$([ "$force" = "true" ] && echo "Оновлення" || echo "Встановлення") $bin ($tag) з $repo..."
    install_asset "https://github.com/$repo/releases/download/$tag/$asset" "$asset" "$bin"
    install_links "$bin" "$links"
  done < "$CONFIG_DIR/github.txt"
}

sync_gitlab() {
  local force="$1"
  local line repo pat bin proj json tag url
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -n "${line// }" ] || continue
    IFS='|' read -r repo pat bin <<< "$line"
    [ -n "${repo:-}" ] && [ -n "${bin:-}" ] || continue

    if [ "$force" = "false" ] && command -v "$bin" >/dev/null 2>&1; then
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
    info "$([ "$force" = "true" ] && echo "Оновлення" || echo "Встановлення") $bin ($tag) з $repo..."
    install_asset "$url" "$(basename "$url")" "$bin"
  done < "$CONFIG_DIR/gitlab.txt"
}

sync_git() {
  local force="$1"
  local line url dir
  mkdir -p "$HOME/Development"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -n "${line// }" ] || continue
    IFS='|' read -r url dir <<< "$line"
    [ -n "${url:-}" ] && [ -n "${dir:-}" ] || continue

    local dest="$HOME/Development/$dir"
    if [ -d "$dest/.git" ]; then
      if [ "$force" = "true" ]; then
        info "git pull у $dest..."
        git -C "$dest" pull --ff-only || warn "не вдалося оновити $dir"
      else
        info "$dir вже існує, пропускаю"
      fi
    elif [ -d "$dest" ]; then
      warn "$dir існує, але не є git-репозиторієм, пропускаю"
    else
      info "Клонування $url → $dest"
      git clone "$url" "$dest"
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

update_uv() {
  command -v uv >/dev/null 2>&1 || { warn "uv не знайдено, пропускаю"; return 0; }
  if [ "$(uv tool list 2>/dev/null | wc -l)" -eq 0 ]; then
    warn "Немає встановлених uv-інструментів, пропускаю"
    return 0
  fi
  info "Оновлення uv-інструментів..."
  uv tool upgrade --all
}

sync_custom() {
  [ -d "$SCRIPT_DIR/custom-bin" ] || return 0
  local count
  count="$(ls -1 "$SCRIPT_DIR/custom-bin" 2>/dev/null | wc -l)"
  [ "$count" -eq 0 ] && return 0
  info "Синхронізація custom-bin/ у /usr/local/bin..."
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

update_zsh() {
  [ -d "$HOME/.oh-my-zsh" ] || { warn "Oh My Zsh не знайдено, пропускаю"; return 0; }
  info "Оновлення Oh My Zsh..."
  git -C "$HOME/.oh-my-zsh" pull --ff-only 2>/dev/null || warn "Не вдалося оновити Oh My Zsh"

  local ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  local line repo plugin
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -n "${line// }" ] || continue
    repo="$line"
    plugin="${repo##*/}"
    if [ ! -d "$ZSH_CUSTOM/plugins/$plugin/.git" ]; then
      info "Встановлення плагіна $plugin..."
      git clone --depth 1 "https://github.com/$repo.git" "$ZSH_CUSTOM/plugins/$plugin"
    else
      info "Оновлення плагіна $plugin..."
      git -C "$ZSH_CUSTOM/plugins/$plugin" pull --ff-only 2>/dev/null || warn "Не вдалося оновити $plugin"
    fi
  done < "$CONFIG_DIR/zsh-plugins.txt"
}

run_install() {
  info "Початок встановлення: $(uname -srm)"
  $RUN_APT    && install_apt
  $RUN_ASDF   && install_asdf
  $RUN_BREW   && install_brew
  $RUN_NVM    && install_node
  $RUN_GITHUB && sync_github false
  $RUN_GITLAB && sync_gitlab false
  $RUN_GIT    && sync_git false
  $RUN_UV     && install_uv
  $RUN_CUSTOM && sync_custom
  $RUN_ZSH    && install_zsh
  info "Готово! Перезапустіть шелл або виконайте 'source ~/.zshrc'"
}

run_update() {
  info "Початок оновлення: $(uname -srm)"
  $RUN_APT    && update_apt
  $RUN_ASDF   && update_asdf
  $RUN_BREW   && update_brew
  $RUN_NVM    && update_node
  $RUN_GITHUB && sync_github true
  $RUN_GITLAB && sync_gitlab true
  $RUN_GIT    && sync_git true
  $RUN_UV     && update_uv
  $RUN_CUSTOM && sync_custom
  $RUN_ZSH    && update_zsh
  info "Готово!"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      install) MODE="install"; shift; break ;;
      update)  MODE="update"; shift; break ;;
      -h|--help) usage; exit 0 ;;
      *) error "Першим аргументом має бути install або update"; usage; exit 1 ;;
    esac
  done

  if [ -z "$MODE" ]; then
    error "Не вказано команду (install|update)"
    usage
    exit 1
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      *) parse_source_flag "$1" || { error "Невідомий параметр: $1"; usage; exit 1; } ;;
    esac
    shift
  done

  if [ "$MODE" = "install" ] && no_sources_selected; then
    error "Вкажіть хоча б одне джерело або --all"
    usage
    exit 1
  fi

  if [ "$MODE" = "update" ] && no_sources_selected; then
    warn "Без аргументів - оновлення всіх джерел"
    set_all
  fi

  if [ "$MODE" = "install" ]; then
    run_install
  else
    run_update
  fi
}

main "$@"