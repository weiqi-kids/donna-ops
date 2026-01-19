#!/usr/bin/env bash
###############################################
# logging.sh
# 結構化日誌功能
#   - log_init()   初始化日誌
#   - log_debug()  除錯訊息
#   - log_info()   一般訊息
#   - log_warn()   警告訊息
#   - log_error()  錯誤訊息
#   - log_audit()  稽核紀錄（修復動作）
###############################################

if [[ -n "${LOGGING_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
LOGGING_SH_LOADED=1

# 全域變數
declare -g LOG_FILE=""
declare -g LOG_LEVEL="INFO"  # DEBUG, INFO, WARN, ERROR
declare -g LOG_TO_STDOUT="true"
declare -g LOG_JSON="false"
declare -g AUDIT_LOG_FILE=""

# 日誌等級對應數值
declare -gA LOG_LEVELS=(
  [DEBUG]=0
  [INFO]=1
  [WARN]=2
  [ERROR]=3
)

# 初始化日誌
# 用法：log_init "/path/to/logs" "INFO"
log_init() {
  local log_dir="${1:-}"
  local level="${2:-INFO}"

  if [[ -z "$log_dir" ]]; then
    local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    log_dir="${script_dir}/logs"
  fi

  # 建立日誌目錄
  mkdir -p "$log_dir"

  LOG_FILE="${log_dir}/donna-ops.log"
  AUDIT_LOG_FILE="${log_dir}/audit.log"
  LOG_LEVEL="${level^^}"

  # 確保日誌檔案可寫入
  touch "$LOG_FILE" 2>/dev/null || {
    echo "ERROR: 無法寫入日誌檔：$LOG_FILE" >&2
    return 1
  }

  touch "$AUDIT_LOG_FILE" 2>/dev/null || {
    echo "ERROR: 無法寫入稽核日誌：$AUDIT_LOG_FILE" >&2
    return 1
  }

  return 0
}

# 內部函式：檢查是否應該記錄此等級
_should_log() {
  local level="$1"
  local current_level="${LOG_LEVELS[$LOG_LEVEL]:-1}"
  local msg_level="${LOG_LEVELS[$level]:-1}"
  (( msg_level >= current_level ))
}

# 內部函式：格式化並輸出日誌
_log() {
  local level="$1"
  local message="$2"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  if ! _should_log "$level"; then
    return 0
  fi

  local formatted
  if [[ "$LOG_JSON" == "true" ]]; then
    # JSON 格式
    local escaped_msg
    escaped_msg=$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g')
    formatted=$(printf '{"timestamp":"%s","level":"%s","message":"%s"}' \
      "$timestamp" "$level" "$escaped_msg")
  else
    # 純文字格式
    formatted=$(printf '[%s] [%-5s] %s' "$timestamp" "$level" "$message")
  fi

  # 輸出到檔案
  if [[ -n "$LOG_FILE" ]]; then
    echo "$formatted" >> "$LOG_FILE"
  fi

  # 輸出到 stdout
  if [[ "$LOG_TO_STDOUT" == "true" ]]; then
    case "$level" in
      ERROR) echo "$formatted" >&2 ;;
      WARN)  echo "$formatted" >&2 ;;
      *)     echo "$formatted" ;;
    esac
  fi
}

# 除錯訊息
log_debug() {
  _log "DEBUG" "$*"
}

# 一般訊息
log_info() {
  _log "INFO" "$*"
}

# 警告訊息
log_warn() {
  _log "WARN" "$*"
}

# 錯誤訊息
log_error() {
  _log "ERROR" "$*"
}

# 稽核紀錄（專門記錄修復動作）
# 用法：log_audit "action_name" "target" "result" "details"
log_audit() {
  local action="$1"
  local target="${2:-}"
  local result="${3:-}"
  local details="${4:-}"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  if [[ -z "$AUDIT_LOG_FILE" ]]; then
    echo "WARN: 稽核日誌未初始化" >&2
    return 1
  fi

  local audit_entry
  if [[ "$LOG_JSON" == "true" ]]; then
    local escaped_details
    escaped_details=$(echo "$details" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g')
    audit_entry=$(printf '{"timestamp":"%s","action":"%s","target":"%s","result":"%s","details":"%s"}' \
      "$timestamp" "$action" "$target" "$result" "$escaped_details")
  else
    audit_entry=$(printf '[%s] ACTION=%s TARGET=%s RESULT=%s DETAILS=%s' \
      "$timestamp" "$action" "$target" "$result" "$details")
  fi

  echo "$audit_entry" >> "$AUDIT_LOG_FILE"

  # 同時記錄到一般日誌
  log_info "AUDIT: $action on $target => $result"
}

# 設定日誌等級
log_set_level() {
  local level="${1^^}"
  if [[ -n "${LOG_LEVELS[$level]:-}" ]]; then
    LOG_LEVEL="$level"
  else
    echo "ERROR: 無效的日誌等級：$level" >&2
    return 1
  fi
}

# 啟用/停用 stdout 輸出
log_set_stdout() {
  local enabled="$1"
  case "${enabled,,}" in
    true|yes|1|on)  LOG_TO_STDOUT="true" ;;
    false|no|0|off) LOG_TO_STDOUT="false" ;;
  esac
}

# 啟用 JSON 格式
log_set_json() {
  local enabled="$1"
  case "${enabled,,}" in
    true|yes|1|on)  LOG_JSON="true" ;;
    false|no|0|off) LOG_JSON="false" ;;
  esac
}

# 取得日誌檔路徑
log_get_file() {
  echo "$LOG_FILE"
}

# 取得稽核日誌路徑
log_get_audit_file() {
  echo "$AUDIT_LOG_FILE"
}

# 日誌輪替設定
declare -g LOG_ROTATE_MAX_SIZE="${LOG_ROTATE_MAX_SIZE:-10485760}"  # 10MB
declare -g LOG_ROTATE_KEEP="${LOG_ROTATE_KEEP:-5}"

# 輪替日誌檔（保留最近 N 個備份）
# 用法: log_rotate [keep_count]
log_rotate() {
  local keep="${1:-$LOG_ROTATE_KEEP}"

  if [[ -z "$LOG_FILE" || ! -f "$LOG_FILE" ]]; then
    return 0
  fi

  local log_dir
  log_dir=$(dirname "$LOG_FILE")
  local log_name
  log_name=$(basename "$LOG_FILE")

  # 刪除舊備份
  local count=0
  for f in $(ls -t "${log_dir}/${log_name}."* 2>/dev/null); do
    (( count++ ))
    if (( count > keep )); then
      rm -f "$f"
    fi
  done

  # 重新命名目前日誌
  local timestamp
  timestamp=$(date '+%Y%m%d-%H%M%S')
  mv "$LOG_FILE" "${LOG_FILE}.${timestamp}"
  touch "$LOG_FILE"

  log_info "日誌已輪替：${log_name}.${timestamp}"
}

# 檢查並自動輪替日誌（如果超過大小限制）
# 用法: log_rotate_if_needed [max_size_bytes]
log_rotate_if_needed() {
  local max_size="${1:-$LOG_ROTATE_MAX_SIZE}"

  if [[ -z "$LOG_FILE" || ! -f "$LOG_FILE" ]]; then
    return 0
  fi

  local current_size
  current_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo "0")

  if (( current_size >= max_size )); then
    log_rotate
    return 0
  fi

  return 1
}

# 設定日誌輪替大小限制
# 用法: log_set_rotate_size size_in_bytes
log_set_rotate_size() {
  LOG_ROTATE_MAX_SIZE="$1"
}

# 設定保留的日誌備份數量
# 用法: log_set_rotate_keep count
log_set_rotate_keep() {
  LOG_ROTATE_KEEP="$1"
}

# 清理過期的日誌檔案
# 用法: log_cleanup [days_to_keep]
log_cleanup() {
  local days="${1:-30}"

  if [[ -z "$LOG_FILE" ]]; then
    return 0
  fi

  local log_dir
  log_dir=$(dirname "$LOG_FILE")

  # 刪除超過指定天數的日誌
  find "$log_dir" -name "*.log.*" -type f -mtime +"$days" -delete 2>/dev/null || true

  # 記錄清理動作
  log_debug "已清理 $days 天前的日誌檔案"
}

# 取得日誌統計
# 用法: log_stats
log_stats() {
  if [[ -z "$LOG_FILE" ]]; then
    echo '{"error": "Log file not initialized"}'
    return 1
  fi

  local log_dir
  log_dir=$(dirname "$LOG_FILE")

  local main_size=0
  local backup_count=0
  local total_size=0

  if [[ -f "$LOG_FILE" ]]; then
    main_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo "0")
  fi

  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    local fsize
    fsize=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo "0")
    ((total_size += fsize))
    ((backup_count++))
  done < <(ls "${LOG_FILE}."* 2>/dev/null)

  ((total_size += main_size))

  cat <<EOF
{
  "log_file": "$LOG_FILE",
  "main_size_bytes": $main_size,
  "backup_count": $backup_count,
  "total_size_bytes": $total_size,
  "max_size_bytes": $LOG_ROTATE_MAX_SIZE,
  "keep_backups": $LOG_ROTATE_KEEP
}
EOF
}
