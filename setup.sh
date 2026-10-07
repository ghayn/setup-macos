#!/bin/bash
if [ -z "${BASH_VERSION:-}" ]; then
  printf '%s\n' '请使用 /bin/bash 运行安装脚本。' >&2
  exit 1
fi
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$SCRIPT_DIR/utils.sh"
# shellcheck source=rollback.sh
source "$SCRIPT_DIR/rollback.sh"

parse_options() {
  DRY_RUN=0 WITH_EXTRA=0 WITH_DOTFILES=1 SKIP_CASKS=0 SKIP_RUNTIMES=0 SKIP_SHELL=0 SKIP_RUST=0
  TEST_ENVIRONMENT=0
  if [[ "${INSTALLER_ENV:-}" == test || "${CI:-}" == 1 || "${CI:-}" == true ]]; then
    TEST_ENVIRONMENT=1
  fi
  while (( $# )); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --test) TEST_ENVIRONMENT=1 ;;
      --with-extra) WITH_EXTRA=1 ;;
      --with-dotfiles) WITH_DOTFILES=1 ;;
      --skip-dotfiles) WITH_DOTFILES=0 ;;
      --skip-casks) SKIP_CASKS=1 ;;
      --skip-runtimes) SKIP_RUNTIMES=1 ;;
      --skip-shell) SKIP_SHELL=1 ;;
      --skip-rust) SKIP_RUST=1 ;;
      -h|--help) /bin/bash "$SCRIPT_DIR/install.sh" --help; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
    shift
  done
  if (( TEST_ENVIRONMENT )); then SKIP_CASKS=1; fi
  (( ! WITH_DOTFILES || ! SKIP_SHELL )) || die '--skip-shell 需同时指定 --skip-dotfiles（个人配置包含 shell 文件）。'
}

print_plan() {
  log '安装计划'
  if (( TEST_ENVIRONMENT )); then
    printf '%s\n' '• 测试环境：跳过所有 cask 应用和字体（包括扩展清单）'
  fi
  printf '%s\n' '• 检查 / 安装 Command Line Tools、Homebrew'
  local manifest
  for manifest in "$SCRIPT_DIR/brewfile" "$SCRIPT_DIR/brewfile-extra"; do
    [[ "$manifest" != */brewfile-extra || "$WITH_EXTRA" == 1 ]] || continue
    awk -v skip="$SKIP_CASKS" '/^brew / || (/^cask / && !skip) { print "  " $0 }' "$manifest"
  done
  (( SKIP_SHELL )) || printf '%s\n' '• 配置 Zim 和 tmux；已有配置先备份，已有 tmux 配置保留'
  (( ! WITH_DOTFILES )) || printf '%s\n' '• 备份并应用 ghayn/dotfiles，迁移旧 exa / asdf / Cargo 设置'
  if (( ! SKIP_RUNTIMES )); then
    printf '• mise 管理 Node.js: %s；Ruby: %s；Python: %s\n' "${NODEJS_VERSION:-当前 LTS}" "${RUBY_VERSION:-最新稳定版}" "${PYTHON_VERSION:-最新稳定版}"
    printf '%s\n' '• pnpm、pip、Poetry（独立虚拟环境）'
  fi
  (( SKIP_RUST )) || printf '%s\n' '• Rust stable（rustup）'
  printf '%s\n' '• 配置 Homebrew 和开发工具 PATH'
}

install_packages() {
  log '安装 Homebrew 工具和应用（保留已安装版本）'
  local manifest selected
  for manifest in "$SCRIPT_DIR/brewfile" "$SCRIPT_DIR/brewfile-extra"; do
    [[ "$manifest" != */brewfile-extra || "$WITH_EXTRA" == 1 ]] || continue
    selected="$manifest"
    if (( SKIP_CASKS )); then
      selected="$SETUP_TMP/$(basename "$manifest")"
      sed '/^[[:space:]]*cask[[:space:]]/d' "$manifest" > "$selected"
    fi
    "$BREW" bundle install --file="$selected" --no-upgrade
  done
}

apply_dotfiles() {
  (( WITH_DOTFILES )) || return 0
  log '备份并应用 ghayn/dotfiles'
  # Use a separate source to avoid replacing an existing chezmoi repository.
  local dot_source="$SETUP_TMP/dotfiles" file
  local -a chezmoi_cmd=(chezmoi --source "$dot_source" --destination "$HOME"
    --config "$SETUP_TMP/chezmoi.toml" --persistent-state "$SETUP_TMP/chezmoi-state.boltdb"
    --cache "$SETUP_TMP/chezmoi-cache")
  : > "$SETUP_TMP/chezmoi.toml"
  git clone --depth 1 https://github.com/ghayn/dotfiles.git "$dot_source"
  "${chezmoi_cmd[@]}" managed --include=dirs --path-style=absolute --nul-path-separator > "$SETUP_TMP/managed-dirs"
  while IFS= read -r -d '' file; do track_directory "$file"; done < "$SETUP_TMP/managed-dirs"
  "${chezmoi_cmd[@]}" managed --include=files,symlinks --path-style=absolute --nul-path-separator > "$SETUP_TMP/managed-files"
  while IFS= read -r -d '' file; do backup_file "$file"; done < "$SETUP_TMP/managed-files"
  "${chezmoi_cmd[@]}" apply --force --include=files,symlinks,dirs
  # Migrate the known legacy settings in this personal repository only.
  if [[ -f "$HOME/.zimrc" ]]; then
    backup_file "$HOME/.zimrc"
    # eza is already installed by Brewfile and aliased in dot_zshenv. There is
    # no zimfw/eza module to substitute for the old exa module.
    sed -E '/^[[:space:]]*zmodule[[:space:]]+(asdf|exa)[[:space:]]*$/d' \
      "$HOME/.zimrc" > "$SETUP_TMP/zimrc"
    cat "$SETUP_TMP/zimrc" > "$HOME/.zimrc"
  fi
  if [[ -f "$HOME/.zshenv" ]]; then
    backup_file "$HOME/.zshenv"
    sed 's|export CARGO_HOME="$HOME/.cargo/bin"|export CARGO_HOME="$HOME/.cargo"|; s|add_to_path_if_missing "$CARGO_HOME"|add_to_path_if_missing "$CARGO_HOME/bin"|' \
      "$HOME/.zshenv" > "$SETUP_TMP/zshenv"
    cat "$SETUP_TMP/zshenv" > "$HOME/.zshenv"
  fi
}

configure_environment() {
  log '配置终端环境'
  local zdot="${ZDOTDIR:-$HOME}" line legacy_line
  # Remove the exact PATH entry emitted by earlier versions of this installer.
  # Keep arbitrary user shell code and the old asdf installations untouched.
  legacy_line='typeset -U path; path=("${ASDF_DATA_DIR:-$HOME/.asdf}/shims" "${CARGO_HOME:-$HOME/.cargo}/bin" "$HOME/.local/bin" $path)'
  if [[ -f "$zdot/.zshrc" ]] && grep -Fqx -- "$legacy_line" "$zdot/.zshrc"; then
    backup_file "$zdot/.zshrc"
    awk -v legacy="$legacy_line" '$0 != legacy' "$zdot/.zshrc" > "$SETUP_TMP/zshrc"
    cat "$SETUP_TMP/zshrc" > "$zdot/.zshrc"
  fi
  printf -v line 'eval "$(%s shellenv)"' "$BREW"
  append_once "$zdot/.zprofile" "$line"
  append_once "$zdot/.zshrc" "$line"
  append_once "$zdot/.zshrc" 'typeset -U path; path=("${CARGO_HOME:-$HOME/.cargo}/bin" "$HOME/.local/bin" $path)'
  printf -v line 'eval "$(%s activate zsh --shims)"' "$BREW_PREFIX/bin/mise"
  append_once "$zdot/.zprofile" "$line"
  printf -v line 'eval "$(%s activate zsh)"' "$BREW_PREFIX/bin/mise"
  append_once "$zdot/.zshrc" "$line"
  export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
  # Repair an inherited value from the old personal dotfiles.
  if [[ "$CARGO_HOME" == "$HOME/.cargo/bin" ]]; then export CARGO_HOME="$HOME/.cargo"; fi
  export PATH="$CARGO_HOME/bin:$HOME/.local/bin:$PATH"
}

install_zimfw() {
  log '配置 Zim'
  local zdot="${ZDOTDIR:-$HOME}" zim_home line
  zim_home="${ZIM_HOME:-$zdot/.zim}"
  track_path "$zim_home"
  mkdir -p "$zim_home"
  if [[ ! -e "$zim_home/zimfw.zsh" ]]; then
    ln -s "$BREW_PREFIX/opt/zimfw/share/zimfw.zsh" "$zim_home/zimfw.zsh"
  fi
  if [[ ! -e "$zdot/.zimrc" ]]; then
    track_path "$zdot/.zimrc"
    printf '%s\n' 'zmodule environment' 'zmodule git' 'zmodule completion' > "$zdot/.zimrc"
  fi
  ZIM_HOME="$zim_home" ZDOTDIR="$zdot" /bin/zsh -df "$zim_home/zimfw.zsh" install
  # Personal dotfiles already initialize Zim; don't initialize modules twice.
  if ! grep -Eq '^[[:space:]]*(source|\.)[[:space:]].*(init\.zsh|zimfw\.zsh)' "$zdot/.zshrc"; then
    printf -v line 'ZIM_HOME=%q' "$zim_home"
    append_once "$zdot/.zshrc" "$line"
    printf -v line 'source %q' "$zim_home/init.zsh"
    append_once "$zdot/.zshrc" "$line"
  fi
}

install_tmux_config() {
  log '配置 tmux'
  local target="$HOME/.tmux" file
  # Preserve an existing tmux setup, including an XDG configuration.
  for file in "$HOME/.tmux.conf" "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"; do
    if [[ -e "$file" || -L "$file" ]]; then log "保留已有 tmux 配置：$file"; return; fi
  done
  if [[ ! -e "$target" ]]; then
    track_path "$target"
    git clone --depth 1 https://github.com/gpakosz/.tmux.git "$target"
  fi
  [[ -f "$target/.tmux.conf" ]] || die "$target 已存在但不是有效的 tmux 配置仓库，请整理后重试。"
  track_path "$HOME/.tmux.conf"
  ln -s "$target/.tmux.conf" "$HOME/.tmux.conf"
  if [[ ! -e "$HOME/.tmux.conf.local" ]]; then
    track_path "$HOME/.tmux.conf.local"
    cp "$target/.tmux.conf.local" "$HOME/.tmux.conf.local"
  fi
}

install_runtimes() {
  log '通过 mise 安装 Node.js、Ruby、Python'
  local tool version node_version ruby_version python_version
  local mise_bin="$BREW_PREFIX/bin/mise"
  local mise_config="${MISE_GLOBAL_CONFIG_FILE:-${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}/config.toml}"
  # These also include existing runtime packages modified by npm / pip.
  track_path "${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}"
  track_path "${MISE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/Library/Caches}/mise}"
  track_path "${MISE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/mise}"
  track_path "${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}"
  if [[ -n "${MISE_INSTALLS_DIR:-}" ]]; then track_path "$MISE_INSTALLS_DIR"; fi
  if [[ -n "${MISE_SHIMS_DIR:-}" ]]; then track_path "$MISE_SHIMS_DIR"; fi
  node_version="${NODEJS_VERSION:-}"
  if [[ -z "$node_version" ]]; then node_version="$("$mise_bin" latest node@lts)"; fi
  ruby_version="${RUBY_VERSION:-}"
  if [[ -z "$ruby_version" ]]; then ruby_version="$("$mise_bin" latest ruby)"; fi
  python_version="${PYTHON_VERSION:-}"
  if [[ -z "$python_version" ]]; then python_version="$("$mise_bin" latest python)"; fi
  for tool in node ruby python; do
    case "$tool" in
      node) version="$node_version" ;;
      ruby) version="$ruby_version" ;;
      python) version="$python_version" ;;
    esac
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$tool 版本无效：${version}；请指定完整稳定版本号。"
  done
  local -a runtimes=("node@$node_version" "ruby@$ruby_version" "python@$python_version")
  backup_file "$mise_config"
  track_path "${mise_config%.toml}.lock"
  "$mise_bin" use --global --pin "${runtimes[@]}"
  # Explicit tool arguments avoid depending on shell activation or project defaults.
  local node_prefix
  node_prefix="$("$mise_bin" where "node@$node_version")"
  track_path "$node_prefix"
  "$mise_bin" exec "${runtimes[@]}" -- npm install --global --prefix "$node_prefix" --cache "$SETUP_TMP/npm-cache" pnpm
  "$mise_bin" exec "${runtimes[@]}" -- python -m pip --isolated --no-cache-dir install --upgrade pip
  local poetry_env="$HOME/.local/share/mac-bootstrap/poetry"
  track_path "$poetry_env"
  "$mise_bin" exec "${runtimes[@]}" -- python -m venv "$poetry_env"
  "$poetry_env/bin/python" -m pip --isolated --no-cache-dir install --upgrade poetry
  track_directory "$HOME/.local/bin"
  mkdir -p "$HOME/.local/bin"
  if [[ ! -e "$HOME/.local/bin/poetry" && ! -L "$HOME/.local/bin/poetry" ]]; then
    track_path "$HOME/.local/bin/poetry"
    ln -s "$poetry_env/bin/poetry" "$HOME/.local/bin/poetry"
  else
    warn '保留已有 ~/.local/bin/poetry。新 Poetry 已安装到独立虚拟环境。'
  fi
  "$mise_bin" reshim
}

install_rust() {
  log '安装 Rust stable'
  track_path "$CARGO_HOME"
  track_path "${RUSTUP_HOME:-$HOME/.rustup}"
  if [[ -x "$CARGO_HOME/bin/rustup" ]]; then
    "$CARGO_HOME/bin/rustup" toolchain install stable --profile minimal
  else
    fetch https://sh.rustup.rs "$SETUP_TMP/rustup.sh"
    /bin/bash "$SETUP_TMP/rustup.sh" -y --no-modify-path --profile minimal --default-toolchain stable
  fi
}

main() {
  parse_options "$@"
  check_requirements
  print_plan
  if (( DRY_RUN )); then log '预览完成；未安装软件或修改用户配置。'; return; fi
  if (( WITH_DOTFILES )) && [[ "${ZDOTDIR:-$HOME}" != "$HOME" ]]; then
    die 'ghayn/dotfiles 使用 ~/.zshrc；自定义 ZDOTDIR 时请指定 --skip-dotfiles。'
  fi
  SETUP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/setup-macos.XXXXXXXX")"
  CLT_MARKER_CREATED=0
  trap cleanup_setup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'printf "错误：步骤失败（%s:%s）。\n" "${BASH_SOURCE[0]:-setup.sh}" "$LINENO" >&2' ERR
  start_sudo_session
  install_command_line_tools
  install_homebrew
  export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_BUNDLE_NO_UPGRADE=1
  install_packages
  begin_rollback_record
  # Work outside any project mise.toml / .tool-versions file.
  cd "$HOME"
  apply_dotfiles
  configure_environment
  if (( ! SKIP_SHELL )); then install_zimfw; install_tmux_config; fi
  if (( ! SKIP_RUNTIMES )); then install_runtimes; fi
  if (( ! SKIP_RUST )); then install_rust; fi
  finish_rollback_record
  log '安装完成。重新打开终端以加载环境。'
  if [[ -d "$BACKUP_DIR" ]]; then printf '原配置备份：%s\n' "$BACKUP_DIR"; fi
  if (( ! SKIP_CASKS )); then warn 'Karabiner 等应用的系统权限、账户登录及付费激活仍需在应用中完成。'; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
