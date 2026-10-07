#!/bin/bash
# Transaction snapshots for user-owned changes. Never execute stored state as code.

rollback_path() {
  local input="$1" parent suffix
  [[ "$input" == /* && "$input" != *$'\n'* ]] || die "回滚路径必须是绝对路径且不含换行：$input"
  case "$input/" in *'/../'*|*'/./'*|*'//'*) die "回滚路径不能包含 .、.. 或空路径段：$input" ;; esac
  parent="$(dirname -- "$input")"
  suffix="$(basename -- "$input")"
  while [[ ! -e "$parent" && ! -L "$parent" ]]; do
    suffix="$(basename -- "$parent")/$suffix"
    parent="$(dirname -- "$parent")"
  done
  parent="$(cd -P -- "$parent" && pwd)" || return
  printf '%s/%s\n' "${parent%/}" "$suffix"
}

rollback_validate_path() {
  local path="$1" kind="${2:-file}"
  [[ "$path" == "$ROLLBACK_HOME/"* ]] || die "无法完整备份用户目录以外的修改：$path"
  [[ "$path" != "$ROLLBACK_ROOT" && "$path" != "$ROLLBACK_ROOT/"* ]] ||
    die "不能将回滚记录目录或它的父目录作为回滚目标：$path"
  [[ "$kind" == directory-mode || "$ROLLBACK_ROOT" != "$path/"* ]] ||
    die "不能将回滚记录目录的父目录作为内容回滚目标：$path"
  case "$path" in /opt/homebrew|/opt/homebrew/*|/usr/local|/usr/local/*) die "不能回滚 Homebrew 目录：$path" ;; esac
  if [[ -n "${BREW_PREFIX:-}" ]]; then
    [[ "$path" != "$BREW_PREFIX" && "$path" != "$BREW_PREFIX/"* ]] || die "不能回滚 Homebrew 目录：$path"
  fi
}

rollback_set_root() {
  ROLLBACK_HOME="$(cd -P -- "$HOME" && pwd)"
  ROLLBACK_ROOT="$(rollback_path "$HOME/.local/state/mac-bootstrap")"
  [[ "$ROLLBACK_ROOT" == "$ROLLBACK_HOME/"* ]] || die '回滚记录目录必须位于用户目录内。'
}

rollback_lock() {
  rollback_set_root
  (umask 077; mkdir -p "$ROLLBACK_ROOT")
  local lock="$ROLLBACK_ROOT/.lock" pid
  if [[ -d "$lock" && ! -L "$lock" && -f "$lock/pid" ]]; then
    pid="$(cat "$lock/pid")"
    if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$lock/pid"
      rmdir "$lock" || die '无法清理旧安装锁。'
    fi
  fi
  (umask 077; mkdir "$lock") 2>/dev/null || die '已有安装或回滚正在运行，请稍后重试。'
  ROLLBACK_LOCK="$lock"
  printf '%s\n' "$$" > "$lock/pid"
}

rollback_unlock() {
  if [[ -n "${ROLLBACK_LOCK:-}" ]]; then
    rm -f "$ROLLBACK_LOCK/pid"
    rmdir "$ROLLBACK_LOCK" || true
    ROLLBACK_LOCK=''
  fi
}

begin_rollback_record() {
  rollback_lock
  BACKUP_DIR="$ROLLBACK_ROOT/backups/$(date +%Y%m%d-%H%M%S)-$$"
  (umask 077; mkdir -p "$ROLLBACK_ROOT/backups"; mkdir "$BACKUP_DIR"; mkdir -p "$BACKUP_DIR/.rollback-v1/entries")
  ROLLBACK_RECORD="$BACKUP_DIR/.rollback-v1"
  printf '%s\n' "$ROLLBACK_HOME" > "$ROLLBACK_RECORD/home"
  printf '%s\n' installing > "$ROLLBACK_RECORD/status"
  ROLLBACK_SEQUENCE=0
  ROLLBACK_ACTIVE=1
  log "回滚记录：$BACKUP_DIR"
}

rollback_is_tracked() {
  local path="$1" contents="${2:-0}" entry previous kind
  for entry in "$ROLLBACK_RECORD"/entries/*; do
    [[ -f "$entry/ready" ]] || continue
    previous="$(cat "$entry/path")"
    kind="$(cat "$entry/kind")"
    if [[ "$path" == "$previous" ]]; then
      if [[ "$contents" == 1 && ( "$kind" == directory-mode || "$kind" == empty-directory ) ]]; then continue; fi
      return 0
    fi
    if [[ "$kind" == tree || "$kind" == absent ]] && [[ "$path" == "$previous/"* ]]; then return 0; fi
  done
  return 1
}

rollback_new_entry() {
  ROLLBACK_SEQUENCE=$((ROLLBACK_SEQUENCE + 1))
  local id
  printf -v id '%06d' "$ROLLBACK_SEQUENCE"
  ROLLBACK_ENTRY="$ROLLBACK_RECORD/entries/$id"
  (umask 077; mkdir "$ROLLBACK_ENTRY")
  printf '%s\n' "$1" > "$ROLLBACK_ENTRY/path"
  printf '%s\n' "$2" > "$ROLLBACK_ENTRY/kind"
}

track_directory() {
  [[ "${ROLLBACK_ACTIVE:-0}" == 1 ]] || return 0
  local path parent
  path="$(rollback_path "$1")"
  rollback_validate_path "$path" directory-mode
  if rollback_is_tracked "$path"; then return; fi
  parent="$(dirname -- "$path")"
  if [[ ! -d "$parent" ]]; then track_directory "$parent"; fi
  if [[ -L "$path" ]]; then
    track_path "$path"
  elif [[ -d "$path" ]]; then
    rollback_new_entry "$path" directory-mode
    stat -f '%Lp' "$path" > "$ROLLBACK_ENTRY/mode"
    touch "$ROLLBACK_ENTRY/ready"
  elif [[ ! -e "$path" ]]; then
    rollback_new_entry "$path" empty-directory
    touch "$ROLLBACK_ENTRY/ready"
  else
    die "目标目录被其他文件占用：$path"
  fi
}

track_path() {
  [[ "${ROLLBACK_ACTIVE:-0}" == 1 ]] || return 0
  local path parent target entry depth="${2:-0}"
  (( depth < 40 )) || die '符号链接循环，无法创建回滚记录。'
  path="$(rollback_path "$1")"
  rollback_validate_path "$path"
  if rollback_is_tracked "$path" 1; then return; fi
  parent="$(dirname -- "$path")"
  if [[ ! -d "$parent" ]]; then track_directory "$parent"; fi
  # Snapshot the referent as well: append/write operations follow leaf symlinks.
  if [[ -L "$path" ]]; then
    target="$(readlink "$path")"
    if [[ "$target" != /* ]]; then target="$parent/$target"; fi
    track_path "$target" "$((depth + 1))"
  fi
  if [[ -e "$path" || -L "$path" ]]; then
    if [[ -d "$path" && ! -L "$path" ]]; then
      rollback_new_entry "$path" tree
    else
      rollback_new_entry "$path" file
    fi
    entry="$ROLLBACK_ENTRY"
    log "备份：$path"
    cp -pPR -- "$path" "$entry/before"
  else
    rollback_new_entry "$path" absent
    entry="$ROLLBACK_ENTRY"
  fi
  touch "$entry/ready"
}

finish_rollback_record() {
  [[ "${ROLLBACK_ACTIVE:-0}" == 1 ]] || return 0
  printf '%s\n' complete > "$ROLLBACK_RECORD/status"
}

validate_rollback_record() {
  local record="$1" entry path kind resolved
  [[ ! -L "$record" && ! -L "$record/entries" && -d "$record/entries" && -f "$record/home" && -f "$record/status" ]] || die "回滚记录不完整：$record"
  [[ "$(cat "$record/home")" == "$ROLLBACK_HOME" ]] || die "回滚记录不属于当前用户目录：$record"
  for entry in "$record"/entries/*; do
    [[ -f "$entry/ready" ]] || continue
    [[ ! -L "$entry" && -f "$entry/path" && -f "$entry/kind" ]] || die "回滚条目无效：$entry"
    path="$(cat "$entry/path")"
    kind="$(cat "$entry/kind")"
    rollback_validate_path "$path" "$kind"
    resolved="$(rollback_path "$path")"
    [[ "$resolved" == "$path" ]] || die "回滚目标的父目录已改成其他位置，请先恢复目录结构：$path"
    case "$kind" in
      file|tree) [[ -e "$entry/before" || -L "$entry/before" ]] || die "原始快照缺失：$path" ;;
      absent|empty-directory) ;;
      directory-mode) [[ "$(cat "$entry/mode")" =~ ^[0-7]+$ ]] || die "目录权限记录无效：$path" ;;
      *) die "未知回滚类型：$kind" ;;
    esac
  done
}

restore_rollback_record() {
  local record="$1" dry_run="$2" entry path kind retry
  validate_rollback_record "$record"
  local -a entries=("$record"/entries/*)
  local index
  for ((index=${#entries[@]}-1; index>=0; index--)); do
    entry="${entries[index]}"
    [[ -f "$entry/ready" && ! -f "$entry/done" ]] || continue
    path="$(cat "$entry/path")"
    kind="$(cat "$entry/kind")"
    log "回滚：$path"
    (( dry_run )) && continue
    case "$kind" in
      empty-directory)
        # Only prune empty directories; unrelated files added later survive.
        if [[ -d "$path" && ! -L "$path" ]]; then rmdir "$path" 2>/dev/null || true; fi
        ;;
      directory-mode)
        if [[ -d "$path" && ! -L "$path" ]]; then chmod "$(cat "$entry/mode")" "$path"; fi
        ;;
      *)
        if [[ ! -f "$entry/saved-current" ]]; then
          if [[ ! -e "$entry/current" && ! -L "$entry/current" ]] && [[ -e "$path" || -L "$path" ]]; then
            mv -- "$path" "$entry/current"
          fi
          touch "$entry/saved-current"
        fi
        # A previous interrupted restore may have left a partial copy.
        if [[ -e "$path" || -L "$path" ]]; then
          retry="$(mktemp -d "$entry/retry.XXXXXXXX")"
          mv -- "$path" "$retry/current"
        fi
        if [[ "$kind" != absent ]]; then
          mkdir -p -- "$(dirname -- "$path")"
          cp -pPR -- "$entry/before" "$path"
        fi
        ;;
    esac
    touch "$entry/done"
  done
  if (( ! dry_run )); then printf '%s\n' rolled-back > "$record/status"; fi
}
