#!/usr/bin/env bash
###############################################
# state.sh
# 狀態管理功能
#   - state_init()          初始化狀態目錄
#   - state_lock()          取得執行鎖
#   - state_unlock()        釋放執行鎖
#   - state_get_issue()     取得 issue 狀態
#   - state_set_issue()     設定 issue 狀態
#   - state_delete_issue()  刪除 issue 狀態
#   - state_check_cooldown() 檢查冷卻時間
#   - state_set_cooldown()   設定冷卻時間
###############################################

if [[ -n "${STATE_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
STATE_SH_LOADED=1

# 全域變數
declare -g STATE_DIR=""
declare -g LOCK_FILE=""
declare -g LOCK_FD=""

# 初始化狀態目錄
# 用法：state_init "/path/to/state"
state_init() {
  local state_dir="${1:-}"

  if [[ -z "$state_dir" ]]; then
    local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    state_dir="${script_dir}/state"
  fi

  mkdir -p "$state_dir"
  mkdir -p "${state_dir}/issues"
  mkdir -p "${state_dir}/cooldowns"

  STATE_DIR="$state_dir"
  LOCK_FILE="${state_dir}/donna-ops.lock"

  return 0
}

# 取得執行鎖（防止同時執行）
# 用法：state_lock [timeout_seconds]
state_lock() {
  local timeout="${1:-30}"

  if [[ -z "$STATE_DIR" ]]; then
    echo "ERROR: 狀態目錄未初始化" >&2
    return 1
  fi

  # 使用 flock 取得鎖
  exec 200>"$LOCK_FILE"

  if ! flock -w "$timeout" 200; then
    echo "ERROR: 無法取得執行鎖（可能有另一個 donna-ops 正在執行）" >&2
    return 1
  fi

  # 寫入 PID
  echo $$ > "$LOCK_FILE"
  LOCK_FD="200"

  return 0
}

# 釋放執行鎖
state_unlock() {
  if [[ -n "$LOCK_FD" ]]; then
    flock -u "$LOCK_FD" 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
    LOCK_FD=""
  fi

  if [[ -f "$LOCK_FILE" ]]; then
    rm -f "$LOCK_FILE" 2>/dev/null || true
  fi
}

# 產生 issue 的唯一識別碼
# 用法：state_issue_id "cpu_high" "server1"
state_issue_id() {
  local type="$1"
  local target="${2:-default}"
  echo "${type}_${target}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_' '_'
}

# 取得 issue 狀態
# 用法：state_get_issue "issue_id"
# 回傳 JSON 格式的 issue 狀態
state_get_issue() {
  local issue_id="$1"
  local issue_file="${STATE_DIR}/issues/${issue_id}.json"

  if [[ -f "$issue_file" ]]; then
    cat "$issue_file"
  else
    echo ""
  fi
}

# 設定 issue 狀態
# 用法：state_set_issue "issue_id" "github_issue_number" "status" "check_count"
state_set_issue() {
  local issue_id="$1"
  local github_number="${2:-}"
  local status="${3:-open}"
  local check_count="${4:-0}"
  local issue_file="${STATE_DIR}/issues/${issue_id}.json"

  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # 讀取現有資料以保留 created_at
  local created_at="$timestamp"
  local normal_count="${5:-0}"
  if [[ -f "$issue_file" ]]; then
    local existing
    existing=$(cat "$issue_file")
    created_at=$(echo "$existing" | jq -r '.created_at // empty' 2>/dev/null || echo "$timestamp")
  fi

  cat > "$issue_file" <<EOF
{
  "issue_id": "${issue_id}",
  "github_number": ${github_number:-null},
  "status": "${status}",
  "check_count": ${check_count},
  "normal_count": ${normal_count},
  "created_at": "${created_at}",
  "updated_at": "${timestamp}"
}
EOF
}

# 更新 issue 的正常次數（用於確認解決）
state_increment_normal_count() {
  local issue_id="$1"
  local issue_file="${STATE_DIR}/issues/${issue_id}.json"

  if [[ ! -f "$issue_file" ]]; then
    return 1
  fi

  local current
  current=$(cat "$issue_file")
  local normal_count
  normal_count=$(echo "$current" | jq -r '.normal_count // 0' 2>/dev/null || echo "0")
  (( normal_count++ ))

  # 更新
  local github_number status check_count
  github_number=$(echo "$current" | jq -r '.github_number // "null"')
  status=$(echo "$current" | jq -r '.status // "open"')
  check_count=$(echo "$current" | jq -r '.check_count // 0')

  state_set_issue "$issue_id" "$github_number" "$status" "$check_count" "$normal_count"
}

# 重設 issue 的正常次數
state_reset_normal_count() {
  local issue_id="$1"
  local issue_file="${STATE_DIR}/issues/${issue_id}.json"

  if [[ ! -f "$issue_file" ]]; then
    return 1
  fi

  local current
  current=$(cat "$issue_file")
  local github_number status check_count
  github_number=$(echo "$current" | jq -r '.github_number // "null"')
  status=$(echo "$current" | jq -r '.status // "open"')
  check_count=$(echo "$current" | jq -r '.check_count // 0')

  state_set_issue "$issue_id" "$github_number" "$status" "$check_count" "0"
}

# 刪除 issue 狀態
state_delete_issue() {
  local issue_id="$1"
  local issue_file="${STATE_DIR}/issues/${issue_id}.json"

  if [[ -f "$issue_file" ]]; then
    rm -f "$issue_file"
  fi
}

# 列出所有 issue
state_list_issues() {
  local status_filter="${1:-}"

  if [[ ! -d "${STATE_DIR}/issues" ]]; then
    return 0
  fi

  for f in "${STATE_DIR}/issues"/*.json; do
    [[ -f "$f" ]] || continue

    if [[ -n "$status_filter" ]]; then
      local issue_status
      issue_status=$(jq -r '.status' "$f" 2>/dev/null)
      if [[ "$issue_status" != "$status_filter" ]]; then
        continue
      fi
    fi

    cat "$f"
  done
}

# 檢查冷卻時間
# 用法：state_check_cooldown "action_name" "target"
# 回傳：0 = 可以執行，1 = 仍在冷卻中
state_check_cooldown() {
  local action="$1"
  local target="${2:-default}"
  local cooldown_id="${action}_${target}"
  local cooldown_file="${STATE_DIR}/cooldowns/${cooldown_id}"

  if [[ ! -f "$cooldown_file" ]]; then
    return 0
  fi

  local expire_at
  expire_at=$(cat "$cooldown_file")
  local now
  now=$(date +%s)

  if (( now >= expire_at )); then
    rm -f "$cooldown_file"
    return 0
  fi

  return 1
}

# 設定冷卻時間
# 用法：state_set_cooldown "action_name" "target" "seconds"
state_set_cooldown() {
  local action="$1"
  local target="${2:-default}"
  local seconds="${3:-300}"
  local cooldown_id="${action}_${target}"
  local cooldown_file="${STATE_DIR}/cooldowns/${cooldown_id}"

  local expire_at
  expire_at=$(( $(date +%s) + seconds ))
  echo "$expire_at" > "$cooldown_file"
}

# 取得冷卻剩餘時間
state_get_cooldown_remaining() {
  local action="$1"
  local target="${2:-default}"
  local cooldown_id="${action}_${target}"
  local cooldown_file="${STATE_DIR}/cooldowns/${cooldown_id}"

  if [[ ! -f "$cooldown_file" ]]; then
    echo "0"
    return
  fi

  local expire_at now remaining
  expire_at=$(cat "$cooldown_file")
  now=$(date +%s)
  remaining=$(( expire_at - now ))

  if (( remaining < 0 )); then
    remaining=0
  fi

  echo "$remaining"
}

# 清理過期的冷卻檔案
state_cleanup_cooldowns() {
  local now
  now=$(date +%s)

  for f in "${STATE_DIR}/cooldowns"/*; do
    [[ -f "$f" ]] || continue
    local expire_at
    expire_at=$(cat "$f")
    if (( now >= expire_at )); then
      rm -f "$f"
    fi
  done
}

# 清理所有狀態（危險操作）
state_cleanup_all() {
  rm -rf "${STATE_DIR}/issues"/* 2>/dev/null || true
  rm -rf "${STATE_DIR}/cooldowns"/* 2>/dev/null || true
}
