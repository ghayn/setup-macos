#!/bin/bash
if [ -z "${BASH_VERSION:-}" ]; then
  printf '%s\n' '请使用 /bin/bash 运行卸载脚本。' >&2
  exit 1
fi
set -Eeuo pipefail
UNINSTALL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$UNINSTALL_DIR/utils.sh"
# shellcheck source=rollback.sh
source "$UNINSTALL_DIR/rollback.sh"

uninstall_main() {
  local dry_run=0 latest=0 arg record status count=0 legacy=0
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=1 ;;
      --latest) latest=1 ;;
      -h|--help)
        printf '%s\n' 'setup-macos：卸载与回滚' \
          '用法：/bin/bash uninstall.sh [--dry-run] [--latest]' \
          '默认逆序回滚所有新版安装记录，保留 Homebrew 及其安装内容。' \
          '--latest 仅回滚最近一次尚未回滚的安装。'
        return ;;
      *) die "未知卸载参数：$arg" ;;
    esac
  done
  [[ "$(id -u)" != 0 ]] || die '请用原安装用户运行，不要 sudo 整个卸载脚本。'
  rollback_set_root
  if [[ ! -d "$ROLLBACK_ROOT/backups" ]]; then log '未找到安装回滚记录，无需处理。'; return; fi
  if (( ! dry_run )); then
    rollback_lock
    trap rollback_unlock EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
  fi
  local -a records=("$ROLLBACK_ROOT"/backups/*)
  local index
  for ((index=${#records[@]}-1; index>=0; index--)); do
    record="${records[index]}/.rollback-v1"
    if [[ ! -d "$record" ]]; then
      [[ ! -d "${records[index]}" ]] || legacy=$((legacy + 1))
      continue
    fi
    status="$(cat "$record/status")"
    [[ "$status" != rolled-back ]] || continue
    log "处理安装记录：${records[index]}"
    restore_rollback_record "$record" "$dry_run"
    count=$((count + 1))
    (( ! latest )) || break
  done
  if (( dry_run )); then
    log "回滚预览完成，共 ${count} 次安装记录；未修改文件。"
  else
    log "回滚完成，共 ${count} 次安装记录；Homebrew 及其软件已保留。"
    if (( count )); then
      printf '回滚前内容已保存在各条目的 current 中：%s/backups\n' "$ROLLBACK_ROOT"
      printf '%s\n' '请重新打开终端。'
    fi
  fi
  if (( legacy )); then warn "另有 ${legacy} 个旧版备份没有完整回滚清单，已保留，需手动恢复。"; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then uninstall_main "$@"; fi
