#!/usr/bin/env bash
###############################################
# remediation/executor.sh
# 修復動作執行器
#   - execute_remediation()    主執行入口
#   - execute_with_timeout()   有超時的執行
#   - verify_success()         執行後驗證
###############################################

if [[ -n "${REMEDIATION_EXECUTOR_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
REMEDIATION_EXECUTOR_SH_LOADED=1

# 設定
declare -g REMEDIATION_TIMEOUT="${REMEDIATION_TIMEOUT:-300}"
declare -g REMEDIATION_DRY_RUN="${REMEDIATION_DRY_RUN:-false}"
declare -g REMEDIATION_ACTIONS_DIR=""

# 初始化執行器
executor_init() {
  local actions_dir="${1:-}"

  if [[ -z "$actions_dir" ]]; then
    local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    actions_dir="${script_dir}/actions"
  fi

  REMEDIATION_ACTIONS_DIR="$actions_dir"
}

# 載入動作腳本
_load_action() {
  local action_name="$1"
  local action_file="${REMEDIATION_ACTIONS_DIR}/${action_name}.sh"

  if [[ ! -f "$action_file" ]]; then
    echo "ERROR: 找不到動作腳本：$action_file" >&2
    return 1
  fi

  # shellcheck source=/dev/null
  source "$action_file"
  return 0
}

# 主執行入口
# 用法：execute_remediation "action_name" "target" [extra_args...]
execute_remediation() {
  local action_name="$1"
  local target="${2:-}"
  shift 2 || true
  local extra_args=("$@")

  local start_time end_time duration
  start_time=$(date +%s)

  # 1. 安全性檢查
  local safety_check
  safety_check=$(pre_execution_check "$action_name" "$target" 2>/dev/null)

  if [[ -z "$safety_check" ]]; then
    # 如果 safety-check.sh 未載入，嘗試載入
    local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    if [[ -f "${script_dir}/validators/safety-check.sh" ]]; then
      # shellcheck source=/dev/null
      source "${script_dir}/validators/safety-check.sh"
      safety_check=$(pre_execution_check "$action_name" "$target")
    fi
  fi

  local approved
  approved=$(echo "$safety_check" | jq -r '.approved // "false"')
  local risk_level
  risk_level=$(echo "$safety_check" | jq -r '.risk_level // "unknown"')

  # 2. 檢查是否為 dry-run 模式
  if [[ "$REMEDIATION_DRY_RUN" == "true" ]]; then
    cat <<EOF
{
  "action": "$action_name",
  "target": "$target",
  "dry_run": true,
  "status": "skipped",
  "message": "Dry-run 模式，未實際執行",
  "safety_check": $safety_check
}
EOF
    return 0
  fi

  # 3. 對於非低風險動作，拒絕自動執行
  if [[ "$approved" != "true" ]]; then
    local reason
    reason=$(echo "$safety_check" | jq -r '.reason // "未知原因"')
    cat <<EOF
{
  "action": "$action_name",
  "target": "$target",
  "status": "rejected",
  "message": "安全性檢查未通過：$reason",
  "risk_level": "$risk_level",
  "safety_check": $safety_check
}
EOF
    return 1
  fi

  # 4. 載入動作腳本
  if ! _load_action "$action_name"; then
    cat <<EOF
{
  "action": "$action_name",
  "status": "error",
  "message": "無法載入動作腳本"
}
EOF
    return 1
  fi

  # 5. 驗證動作（呼叫 action_validate）
  if type -t action_validate >/dev/null 2>&1; then
    local validate_result
    validate_result=$(action_validate "$target" "${extra_args[@]}" 2>&1)
    local validate_code=$?
    if (( validate_code != 0 )); then
      cat <<EOF
{
  "action": "$action_name",
  "target": "$target",
  "status": "validation_failed",
  "message": "$validate_result"
}
EOF
      return 1
    fi
  fi

  # 6. 執行動作（呼叫 action_execute）
  local exec_output exec_code
  if type -t action_execute >/dev/null 2>&1; then
    exec_output=$(execute_with_timeout "$REMEDIATION_TIMEOUT" action_execute "$target" "${extra_args[@]}" 2>&1)
    exec_code=$?
  else
    exec_output="ERROR: action_execute 函式未定義"
    exec_code=1
  fi

  end_time=$(date +%s)
  duration=$((end_time - start_time))

  # 7. 驗證結果（呼叫 action_verify）
  local verify_result="skipped"
  local verify_message=""
  if (( exec_code == 0 )) && type -t action_verify >/dev/null 2>&1; then
    verify_message=$(action_verify "$target" 2>&1)
    local verify_code=$?
    if (( verify_code == 0 )); then
      verify_result="passed"
    else
      verify_result="failed"
    fi
  fi

  # 8. 產生結果報告
  local status
  if (( exec_code == 0 )); then
    if [[ "$verify_result" == "passed" || "$verify_result" == "skipped" ]]; then
      status="success"
    else
      status="partial"
    fi
  else
    status="failed"
  fi

  # 清理函式
  unset -f action_validate action_execute action_verify 2>/dev/null || true

  cat <<EOF
{
  "action": "$action_name",
  "target": "$target",
  "status": "$status",
  "exit_code": $exec_code,
  "duration_seconds": $duration,
  "output": $(echo "$exec_output" | jq -Rs '.'),
  "verification": {
    "result": "$verify_result",
    "message": $(echo "$verify_message" | jq -Rs '.')
  },
  "risk_level": "$risk_level"
}
EOF

  return $exec_code
}

# 有超時的執行
# 用法：execute_with_timeout 60 command arg1 arg2
execute_with_timeout() {
  local timeout_sec="$1"
  shift
  local cmd=("$@")

  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_sec" "${cmd[@]}"
  else
    # macOS 沒有 timeout，使用 perl 替代
    perl -e 'alarm shift; exec @ARGV' "$timeout_sec" "${cmd[@]}"
  fi
}

# 批次執行修復
# 用法：execute_batch "actions_json"
# actions_json 格式：[{"action": "name", "target": "...", "args": [...]}]
execute_batch() {
  local actions_json="$1"

  local results="[]"
  local success_count=0
  local failed_count=0

  while IFS= read -r action_item; do
    [[ -z "$action_item" || "$action_item" == "null" ]] && continue

    local action_name target args
    action_name=$(echo "$action_item" | jq -r '.action')
    target=$(echo "$action_item" | jq -r '.target // ""')
    # 將 args 陣列轉換為 bash 陣列
    local args_array=()
    while IFS= read -r arg; do
      [[ -n "$arg" ]] && args_array+=("$arg")
    done < <(echo "$action_item" | jq -r '.args[]?' 2>/dev/null)

    # 執行
    local result
    result=$(execute_remediation "$action_name" "$target" "${args_array[@]}")
    local code=$?

    results=$(echo "$results" | jq --argjson r "$result" '. + [$r]')

    if (( code == 0 )); then
      ((success_count++))
    else
      ((failed_count++))
    fi
  done < <(echo "$actions_json" | jq -c '.[]' 2>/dev/null)

  cat <<EOF
{
  "total": $((success_count + failed_count)),
  "success": $success_count,
  "failed": $failed_count,
  "results": $results
}
EOF
}

# 根據分析結果自動執行低風險修復
# 用法：auto_remediate "analysis_json"
auto_remediate() {
  local analysis_json="$1"

  # 只取得低風險且可自動執行的動作
  local auto_actions
  auto_actions=$(echo "$analysis_json" | jq '[.recommendations[] | select(.risk_level == "low" and .auto_executable == true)]' 2>/dev/null)

  if [[ -z "$auto_actions" || "$auto_actions" == "[]" || "$auto_actions" == "null" ]]; then
    echo '{"message": "沒有可自動執行的修復動作", "executed": []}'
    return 0
  fi

  # 轉換格式並執行
  local batch_actions="[]"
  while IFS= read -r action; do
    [[ -z "$action" || "$action" == "null" ]] && continue
    local action_name
    action_name=$(echo "$action" | jq -r '.action')
    batch_actions=$(echo "$batch_actions" | jq --arg a "$action_name" '. + [{"action": $a}]')
  done < <(echo "$auto_actions" | jq -c '.[]' 2>/dev/null)

  execute_batch "$batch_actions"
}

# 設定超時
set_remediation_timeout() {
  REMEDIATION_TIMEOUT="$1"
}

# 設定 dry-run 模式
set_remediation_dry_run() {
  local enabled="$1"
  case "${enabled,,}" in
    true|yes|1|on)  REMEDIATION_DRY_RUN="true" ;;
    false|no|0|off) REMEDIATION_DRY_RUN="false" ;;
  esac
}

# 列出可用的修復動作
list_available_actions() {
  if [[ -z "$REMEDIATION_ACTIONS_DIR" || ! -d "$REMEDIATION_ACTIONS_DIR" ]]; then
    echo '{"actions": []}'
    return 1
  fi

  local actions="[]"
  for f in "$REMEDIATION_ACTIONS_DIR"/*.sh; do
    [[ -f "$f" ]] || continue
    local name
    name=$(basename "$f" .sh)
    local desc=""

    # 嘗試從檔案中提取描述
    desc=$(grep -m1 "^# Description:" "$f" 2>/dev/null | sed 's/^# Description: *//' || echo "")

    actions=$(echo "$actions" | jq --arg n "$name" --arg d "$desc" \
      '. + [{"name": $n, "description": $d}]')
  done

  echo "{\"actions\": $actions}"
}
