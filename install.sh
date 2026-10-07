#!/bin/bash
# Standalone entry point: works from a checkout, a downloaded file, or bash -c.
if [ -z "${BASH_VERSION:-}" ]; then
  printf '%s\n' '请使用 /bin/bash 运行安装脚本（不再使用 zsh）。' >&2
  exit 1
fi
set -Eeuo pipefail

usage() {
  cat <<'HELP'
setup-macos：macOS 开发环境一键安装（macOS 15 及以上，面向 macOS 27 / Apple Silicon）
用法：/bin/bash install.sh [选项]
回滚：/bin/bash install.sh uninstall [--dry-run] [--latest]
  --dry-run          只显示计划，不安装、不修改用户配置
  --test             测试环境：跳过所有 cask 应用和字体
  --with-extra       同时安装 brewfile-extra 中的应用
  --skip-dotfiles    跳过默认启用的 ghayn/dotfiles 个人配置
  --with-dotfiles    显式启用个人配置（默认）
  --skip-casks       不安装 GUI 应用和字体
  --skip-runtimes    不安装 Node.js / Ruby / Python 及其附加工具
  --skip-shell       不配置 Zim / tmux
  --skip-rust        不安装 Rust
  -h, --help         显示帮助
环境变量：INSTALLER_REPO、INSTALLER_REF、NODEJS_VERSION、RUBY_VERSION、PYTHON_VERSION
INSTALLER_ENV=test 或 CI=1/true 也会自动跳过 cask。
HELP
}

bootstrap() {
  local arg source_file source_dir work_dir repo ref action_script=setup.sh
  local -a original_args=("$@")
  if [[ "${1:-}" == uninstall || "${1:-}" == --uninstall ]]; then
    action_script=uninstall.sh
    shift
  fi
  for arg in "$@"; do
    case "$arg" in
      -h|--help) usage; return ;;
      --dry-run|--latest|--test|--with-extra|--with-dotfiles|--skip-dotfiles|--skip-casks|--skip-runtimes|--skip-shell|--skip-rust) ;;
      *) printf '未知参数：%s\n' "$arg" >&2; return 2 ;;
    esac
  done
  [[ "$(uname -s)" == Darwin ]] || { printf '%s\n' '此脚本仅支持 macOS。' >&2; return 1; }

  # Never install Intel Homebrew accidentally from a Rosetta terminal.
  if [[ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" == 1 ]]; then
    printf '%s\n' '检测到 Rosetta，切换至原生 Apple Silicon 环境。'
    if [[ -n "${BASH_EXECUTION_STRING:-}" ]]; then
      exec /usr/bin/arch -arm64 /bin/bash -c "$BASH_EXECUTION_STRING" "$0" "${original_args[@]}"
    else
      exec /usr/bin/arch -arm64 /bin/bash "${BASH_SOURCE[0]}" "${original_args[@]}"
    fi
  fi

  source_file="${BASH_SOURCE[0]:-}"
  if [[ -n "$source_file" && -f "$source_file" ]]; then
    source_dir="$(cd -- "$(dirname -- "$source_file")" && pwd)"
    if [[ -f "$source_dir/$action_script" && -f "$source_dir/utils.sh" && -f "$source_dir/rollback.sh" && -f "$source_dir/brewfile" ]]; then
      /bin/bash "$source_dir/$action_script" "$@"
      return
    fi
  fi

  repo="${INSTALLER_REPO:-ghayn/setup-macos}"
  ref="${INSTALLER_REF:-main}"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { printf '%s\n' 'INSTALLER_REPO 格式应为 owner/repo。' >&2; return 2; }
  [[ "$ref" =~ ^[A-Za-z0-9_./-]+$ ]] || { printf '%s\n' 'INSTALLER_REF 包含不支持的字符。' >&2; return 2; }
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/setup-macos-bootstrap.XXXXXXXX")"
  BOOTSTRAP_TMP="$work_dir"
  # Cleanup only this invocation's private directory, including on interruption.
  trap 'rm -rf -- "$BOOTSTRAP_TMP"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  printf '下载安装文件：%s (%s)\n' "$repo" "$ref"
  curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
    --retry 3 --connect-timeout 20 --max-time 300 \
    "https://codeload.github.com/$repo/tar.gz/$ref" -o "$work_dir/source.tar.gz"
  mkdir "$work_dir/source"
  tar -xzf "$work_dir/source.tar.gz" -C "$work_dir/source" --strip-components=1
  for arg in setup.sh uninstall.sh utils.sh rollback.sh brewfile brewfile-extra; do
    [[ -s "$work_dir/source/$arg" ]] || { printf '安装文件缺失：%s\n' "$arg" >&2; return 1; }
  done
  /bin/bash "$work_dir/source/$action_script" "$@"
  rm -rf -- "$work_dir"
  trap - EXIT
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]; then
  bootstrap "$@"
fi
