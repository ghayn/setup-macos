#!/bin/bash
# Shared helpers, compatible with macOS /bin/bash 3.2.
log() { printf '\n==> %s\n' "$*"; }
warn() { printf '提示：%s\n' "$*" >&2; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

fetch() {
  curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
    --retry 3 --connect-timeout 20 --max-time 300 "$1" -o "$2"
}

check_requirements() {
  local major machine
  [[ "$(uname -s)" == Darwin ]] || die '此脚本仅支持 macOS。'
  OS_VERSION="$(sw_vers -productVersion)"
  major="${OS_VERSION%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] || die "无法识别 macOS 版本：$OS_VERSION"
  (( major >= 15 )) || die "macOS $OS_VERSION 不在本脚本支持范围内，请升级到 macOS 15 或更新版本。"
  [[ "$(id -u)" != 0 ]] || die '请用普通管理员账户运行，不要 sudo 整个脚本。'
  machine="$(uname -m)"
  case "$machine" in
    arm64) BREW_PREFIX=/opt/homebrew ;;
    x86_64)
      [[ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" != 1 ]] || die '请从 install.sh 启动，以自动切换到 Apple Silicon 原生环境。'
      (( major < 27 )) || die 'macOS 27 安装目标必须是 Apple Silicon。'
      BREW_PREFIX=/usr/local
      warn 'Intel Mac 仅作尽力兼容；Homebrew 将其列为 Tier 3。'
      ;;
    *) die "不支持的处理器架构：$machine" ;;
  esac
  BREW="$BREW_PREFIX/bin/brew"
  log "macOS $OS_VERSION / $machine"
}

backup_file() {
  local file="$1" target
  if [[ "${ROLLBACK_ACTIVE:-0}" == 1 ]]; then track_path "$file"; return; fi
  [[ -e "$file" || -L "$file" ]] || return 0
  [[ "$file" == "$HOME/"* ]] || die "备份目标不在用户目录：$file"
  target="$BACKUP_DIR/${file#"$HOME/"}"
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    (umask 077; mkdir -p -- "$(dirname -- "$target")"; cp -pP -- "$file" "$target")
  fi
}

dotfiles_manages_path() {
  local file="$1" managed
  [[ -n "${SETUP_TMP:-}" && -f "$SETUP_TMP/managed-files" ]] || return 1
  while IFS= read -r -d '' managed; do
    if [[ "$file" == "$managed" || "$file" == "$managed/"* || "$file" -ef "$managed" ]]; then return 0; fi
  done < "$SETUP_TMP/managed-files"
  return 1
}

append_once() {
  local file="$1" line="$2"
  if dotfiles_manages_path "$file"; then return; fi
  if [[ -f "$file" ]] && grep -Fqx -- "$line" "$file"; then return; fi
  backup_file "$file"
  mkdir -p -- "$(dirname -- "$file")"
  printf '\n%s\n' "$line" >> "$file"
}

start_sudo_session() {
  log '请求系统安装权限（密码仅交给系统 sudo）'
  if ! sudo -n -v 2>/dev/null; then
    [[ -t 0 ]] || die '需要管理员权限，请在终端中运行；无人值守运行需预先配置 sudo 权限。'
    sudo -v
  fi
  (
    trap 'if [[ -n "${sleep_pid:-}" ]]; then kill "$sleep_pid" 2>/dev/null || true; fi; exit' TERM INT
    while kill -0 "$$" 2>/dev/null; do
      sudo -n -v 2>/dev/null || exit
      sleep 50 &
      sleep_pid=$!
      wait "$sleep_pid"
      sleep_pid=''
    done
  ) &
  SUDO_KEEPALIVE_PID=$!
}

cleanup_setup() {
  local status=$?
  trap - EXIT
  if declare -F rollback_unlock >/dev/null; then rollback_unlock; fi
  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
  if [[ "${CLT_MARKER_CREATED:-0}" == 1 ]]; then rm -f -- "$CLT_MARKER"; fi
  if [[ -n "${SETUP_TMP:-}" ]]; then rm -rf -- "$SETUP_TMP"; fi
  if (( status != 0 )); then
    warn "安装未完成（退出码 ${status}）。解决上方错误后可重复运行。"
    if [[ -d "${BACKUP_DIR:-}" ]]; then warn "原配置备份：$BACKUP_DIR"; fi
  fi
  exit "$status"
}

command_line_tools_ready() {
  local compiler sdk
  xcode-select -p >/dev/null 2>&1 || return 1
  compiler="$(xcrun --find clang 2>/dev/null)" || return 1
  sdk="$(xcrun --show-sdk-path 2>/dev/null)" || return 1
  [[ -x "$compiler" && -d "$sdk" ]]
}

select_clt_label() {
  # Handles both '* Label: ...' and the older '* Command Line Tools ...'.
  sed -nE 's/^[[:space:]]*\*[[:space:]]*(Label:[[:space:]]*)?(Command Line Tools.*)/\2/p' |
    LC_ALL=C sort -V | tail -n 1
}

install_command_line_tools() {
  log '检查 Xcode Command Line Tools'
  if command_line_tools_ready; then return; fi
  CLT_MARKER=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  if [[ ! -e "$CLT_MARKER" ]]; then
    touch "$CLT_MARKER"
    CLT_MARKER_CREATED=1
  fi
  local updates label
  updates="$(LC_ALL=C softwareupdate --list 2>&1)" || die "无法查询 Command Line Tools：$updates"
  label="$(printf '%s\n' "$updates" | select_clt_label)"
  [[ -n "$label" ]] || die 'Apple 未提供可安装的 Command Line Tools。请运行 xcode-select --install，安装完成后重试。'
  sudo softwareupdate --install "$label" --verbose
  sudo xcode-select --switch /Library/Developer/CommandLineTools
  command_line_tools_ready || die 'Command Line Tools 安装后仍不可用，请检查 Xcode 许可及系统更新后重试。'
  if [[ "$CLT_MARKER_CREATED" == 1 ]]; then rm -f -- "$CLT_MARKER"; CLT_MARKER_CREATED=0; fi
}

install_homebrew() {
  log '安装 / 更新 Homebrew'
  if [[ ! -x "$BREW" ]]; then
    [[ "$BREW_PREFIX" != /usr/local ]] || die '当前官方安装器面向 Apple Silicon；Intel Mac 请先自行安装兼容的 Homebrew。'
    fetch https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh "$SETUP_TMP/homebrew.sh"
    NONINTERACTIVE=1 /bin/bash "$SETUP_TMP/homebrew.sh"
  fi
  [[ -x "$BREW" ]] || die "未找到 Homebrew：$BREW"
  local brew_env
  brew_env="$("$BREW" shellenv)"
  eval "$brew_env"
  "$BREW" update
}
