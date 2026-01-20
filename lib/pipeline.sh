#!/usr/bin/env bash
###############################################
# lib/pipeline.sh
# 統一的問題處理流程
#
# 不論問題來源（系統指標超標或 Linode 警報），
# 都使用相同的處理流程：
#   1. 建立/更新 GitHub Issue
#   2. 觸發診斷（AI 分析）
#   3. 嘗試自動修復（低風險）
#   4. 發送通知
###############################################

if [[ -n "${PIPELINE_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
PIPELINE_SH_LOADED=1

# 設定
declare -g PIPELINE_DRY_RUN="${PIPELINE_DRY_RUN:-false}"
declare -g PIPELINE_USE_AI="${PIPELINE_USE_AI:-false}"
declare -g PIPELINE_NORMAL_THRESHOLD="${PIPELINE_NORMAL_THRESHOLD:-3}"

# 狀態回報設定
declare -g PIPELINE_STATUS_REPORT="${PIPELINE_STATUS_REPORT:-false}"
declare -g PIPELINE_STATUS_REPORT_ON_ERROR="${PIPELINE_STATUS_REPORT_ON_ERROR:-true}"

# 主處理流程
# 用法：pipeline_process "alert_summary_json" "system_metrics_json"
# alert_summary 格式：
# {
#   "timestamp": "...",
#   "hostname": "...",
#   "issue_count": N,
#   "max_severity": "ok|minor|warning|critical",
#   "summary": "...",
#   "issues": [...]
# }
pipeline_process() {
  local alert_summary="$1"
  local system_metrics="${2:-}"
  local source="${3:-unknown}"  # 來源：periodic 或 linode

  local issue_count max_severity
  issue_count=$(echo "$alert_summary" | jq -r '.issue_count // 0')
  max_severity=$(echo "$alert_summary" | jq -r '.max_severity // "ok"')

  log_info "[Pipeline] 來源: $source, 問題數: $issue_count, 嚴重度: $max_severity"

  if (( issue_count > 0 )); then
    # 有問題，執行完整處理流程
    _pipeline_handle_issues "$alert_summary" "$system_metrics" "$source"
  else
    # 沒有問題，檢查是否有可以關閉的 Issue
    _pipeline_check_resolved

    # 定期回報狀態（即使正常也回報）
    if [[ "$PIPELINE_STATUS_REPORT" == "true" ]]; then
      local analysis
      analysis=$(quick_analysis "$alert_summary" 2>/dev/null || echo '{}')
      _pipeline_report_status "$system_metrics" "$alert_summary" "$analysis" "periodic"
    fi
  fi
}

# 處理問題
_pipeline_handle_issues() {
  local alert_summary="$1"
  local system_metrics="$2"
  local source="$3"

  local max_severity
  max_severity=$(echo "$alert_summary" | jq -r '.max_severity // "warning"')

  # Step 1: 診斷分析
  log_info "[Pipeline] Step 1: 執行診斷分析..."
  local analysis
  analysis=$(_pipeline_diagnose "$alert_summary" "$system_metrics")

  # Step 2: 對每個問題建立/更新 Issue
  log_info "[Pipeline] Step 2: 處理 GitHub Issues..."
  _pipeline_manage_issues "$alert_summary" "$analysis" "$system_metrics" "$source"

  # Step 3: 嘗試自動修復（低風險）
  log_info "[Pipeline] Step 3: 嘗試自動修復..."
  _pipeline_auto_remediate "$alert_summary" "$analysis"

  # Step 4: 發送通知
  log_info "[Pipeline] Step 4: 發送通知..."
  _pipeline_notify "$alert_summary" "$analysis" "$source"

  # Step 5: 回報狀態到 GitHub（如果啟用且有問題）
  if [[ "$PIPELINE_STATUS_REPORT_ON_ERROR" == "true" ]]; then
    log_info "[Pipeline] Step 5: 回報狀態到 GitHub..."
    _pipeline_report_status "$system_metrics" "$alert_summary" "$analysis" "error"
  fi

  log_info "[Pipeline] 處理完成"
}

# 診斷分析
_pipeline_diagnose() {
  local alert_summary="$1"
  local system_metrics="$2"

  local analysis

  if [[ "$PIPELINE_USE_AI" == "true" ]] && claude_available 2>/dev/null; then
    log_info "[Pipeline] 使用 Claude AI 分析..."
    local log_samples
    log_samples=$(collect_error_summary "30 minutes ago" 2>/dev/null | jq -r '.sample_errors[].message' 2>/dev/null | head -20 || echo "")
    analysis=$(analyze_with_claude "$alert_summary" "$system_metrics" "$log_samples" 2>/dev/null) || {
      log_warn "[Pipeline] AI 分析失敗，改用規則分析"
      analysis=$(quick_analysis "$alert_summary")
    }
  else
    log_info "[Pipeline] 使用規則分析..."
    analysis=$(quick_analysis "$alert_summary")
  fi

  echo "$analysis"
}

# 管理 GitHub Issues
_pipeline_manage_issues() {
  local alert_summary="$1"
  local analysis="$2"
  local system_metrics="$3"
  local source="$4"

  while IFS= read -r issue; do
    [[ -z "$issue" || "$issue" == "null" ]] && continue

    local issue_type metric severity
    issue_type=$(echo "$issue" | jq -r '.type')
    metric=$(echo "$issue" | jq -r '.metric // .container // .alert_type // "unknown"')
    severity=$(echo "$issue" | jq -r '.severity')

    # 產生 issue_id
    local issue_id
    issue_id=$(state_issue_id "${source}_${issue_type}" "$metric")

    log_debug "[Pipeline] 處理問題: $issue_id"

    # 取得現有狀態
    local existing_state
    existing_state=$(state_get_issue "$issue_id")

    if [[ -z "$existing_state" ]]; then
      # 新問題
      _pipeline_create_issue "$issue_id" "$issue" "$alert_summary" "$analysis" "$system_metrics" "$severity" "$issue_type"
    else
      # 現有問題，更新
      _pipeline_update_issue "$issue_id" "$existing_state" "$issue" "$alert_summary"
    fi
  done < <(echo "$alert_summary" | jq -c '.issues[]' 2>/dev/null)
}

# 建立新 Issue
_pipeline_create_issue() {
  local issue_id="$1"
  local issue="$2"
  local alert_summary="$3"
  local analysis="$4"
  local system_metrics="$5"
  local severity="$6"
  local issue_type="$7"

  local metric
  metric=$(echo "$issue" | jq -r '.metric // .container // .alert_type // "unknown"')

  log_info "[Pipeline] 建立新 Issue: $issue_id"

  if [[ "$PIPELINE_DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] 會建立 Issue: $issue_id"
    state_set_issue "$issue_id" "" "open" "1" "0"
    return 0
  fi

  if [[ -n "$GITHUB_REPO" ]]; then
    # 產生標題和內容
    local title="[$issue_type] $metric 異常"
    local body
    body=$(format_issue_body "$alert_summary" "$analysis" "$system_metrics")

    local create_result
    create_result=$(create_or_update_issue "$issue_id" "$title" "$body" "$severity" "$issue_type" 2>/dev/null)
    local github_number
    github_number=$(echo "$create_result" | jq -r '.issue_number // empty')

    # 記錄狀態
    state_set_issue "$issue_id" "$github_number" "open" "1" "0"

    log_info "[Pipeline] Issue 已建立: #$github_number"
  else
    # 沒有 GitHub，只記錄狀態
    state_set_issue "$issue_id" "" "open" "1" "0"
    log_warn "[Pipeline] GitHub 未設定，僅記錄本地狀態"
  fi
}

# 更新現有 Issue
_pipeline_update_issue() {
  local issue_id="$1"
  local existing_state="$2"
  local issue="$3"
  local alert_summary="$4"

  local github_number check_count
  github_number=$(echo "$existing_state" | jq -r '.github_number // empty')
  check_count=$(echo "$existing_state" | jq -r '.check_count // 0')
  ((check_count++))

  log_info "[Pipeline] 更新 Issue: $issue_id (檢查 #$check_count)"

  # 重設正常計數
  state_reset_normal_count "$issue_id"

  if [[ "$PIPELINE_DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] 會更新 Issue: $issue_id"
    state_set_issue "$issue_id" "$github_number" "open" "$check_count" "0"
    return 0
  fi

  if [[ -n "$github_number" && -n "$GITHUB_REPO" ]]; then
    local current_value
    current_value=$(echo "$issue" | jq -r '.current // "N/A"')
    local metric
    metric=$(echo "$issue" | jq -r '.metric // .container // .alert_type // "unknown"')

    local update_comment="### 狀態更新 (檢查 #$check_count)

問題持續存在。

- **指標**: $metric
- **當前值**: $current_value
- **時間**: $(date '+%Y-%m-%d %H:%M:%S')
"
    update_issue "$github_number" "$update_comment" 2>/dev/null || true
  fi

  state_set_issue "$issue_id" "$github_number" "open" "$check_count" "0"
}

# 自動修復
_pipeline_auto_remediate() {
  local alert_summary="$1"
  local analysis="$2"

  if [[ "$PIPELINE_DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] 跳過自動修復"
    return 0
  fi

  # 取得建議的修復動作
  local suggested_actions
  suggested_actions=$(get_suggested_actions "$alert_summary" 2>/dev/null || echo "[]")

  # 如果有 AI 分析，優先使用 AI 的建議
  if [[ -n "$analysis" && "$analysis" != "null" ]]; then
    local ai_actions
    ai_actions=$(get_auto_executable_actions "$analysis" 2>/dev/null || echo "[]")
    if [[ "$ai_actions" != "[]" && "$ai_actions" != "null" ]]; then
      suggested_actions="$ai_actions"
    fi
  fi

  if [[ "$suggested_actions" == "[]" || -z "$suggested_actions" ]]; then
    log_info "[Pipeline] 沒有建議的修復動作"
    return 0
  fi

  local executed=0
  while IFS= read -r action_item; do
    [[ -z "$action_item" || "$action_item" == "null" ]] && continue

    local action_name target
    action_name=$(echo "$action_item" | jq -r '.action')
    target=$(echo "$action_item" | jq -r '.target // ""')

    # 檢查冷卻時間
    if ! state_check_cooldown "$action_name" "$target" 2>/dev/null; then
      local remaining
      remaining=$(state_get_cooldown_remaining "$action_name" "$target" 2>/dev/null || echo "?")
      log_info "[Pipeline] 動作 $action_name 冷卻中（剩餘 ${remaining}s），跳過"
      continue
    fi

    # 嘗試執行
    log_info "[Pipeline] 執行修復: $action_name ${target:+($target)}"
    local exec_result
    exec_result=$(execute_remediation "$action_name" "$target" 2>&1)
    local exec_status
    exec_status=$(echo "$exec_result" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")

    if [[ "$exec_status" == "success" ]]; then
      log_info "[Pipeline] 修復成功: $action_name"
      log_audit "$action_name" "$target" "success" "auto-remediation"
      state_set_cooldown "$action_name" "$target" 300
      ((executed++))
    elif [[ "$exec_status" == "rejected" ]]; then
      local reason
      reason=$(echo "$exec_result" | jq -r '.message // "未知原因"' 2>/dev/null)
      log_info "[Pipeline] 修復被拒絕: $action_name - $reason"
    else
      log_warn "[Pipeline] 修復失敗: $action_name"
      log_audit "$action_name" "$target" "failed" "$exec_result"
    fi
  done < <(echo "$suggested_actions" | jq -c '.[]' 2>/dev/null)

  log_info "[Pipeline] 執行了 $executed 個修復動作"
}

# 發送通知
_pipeline_notify() {
  local alert_summary="$1"
  local analysis="$2"
  local source="$3"

  if [[ "$PIPELINE_DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] 跳過發送通知"
    return 0
  fi

  if ! notify_is_configured 2>/dev/null; then
    log_debug "[Pipeline] 通知未設定，跳過"
    return 0
  fi

  local issue_count max_severity summary
  issue_count=$(echo "$alert_summary" | jq -r '.issue_count // 0')
  max_severity=$(echo "$alert_summary" | jq -r '.max_severity // "warning"')
  summary=$(echo "$alert_summary" | jq -r '.summary // "系統異常"')

  # 根據嚴重度決定通知等級
  local notify_severity="warning"
  case "$max_severity" in
    critical) notify_severity="error" ;;
    warning)  notify_severity="warning" ;;
    minor)    notify_severity="info" ;;
  esac

  # 組合通知訊息
  local message="偵測到 $issue_count 個問題 (來源: $source)

$summary"

  # 加入診斷摘要（如果有）
  if [[ -n "$analysis" && "$analysis" != "null" ]]; then
    local diagnosis
    diagnosis=$(echo "$analysis" | jq -r '.diagnosis // ""' 2>/dev/null)
    if [[ -n "$diagnosis" ]]; then
      message="$message

診斷: $diagnosis"
    fi
  fi

  notify_all "$message" "$notify_severity" 2>/dev/null || true
}

# 檢查已解決的問題
_pipeline_check_resolved() {
  log_info "[Pipeline] 系統正常，檢查是否有可關閉的 Issue..."

  local closed_count=0

  while IFS= read -r state_json; do
    [[ -z "$state_json" ]] && continue

    local issue_id github_number normal_count status
    issue_id=$(echo "$state_json" | jq -r '.issue_id')
    github_number=$(echo "$state_json" | jq -r '.github_number // empty')
    normal_count=$(echo "$state_json" | jq -r '.normal_count // 0')
    status=$(echo "$state_json" | jq -r '.status // "open"')

    [[ "$status" != "open" ]] && continue

    # 增加正常計數
    state_increment_normal_count "$issue_id"
    ((normal_count++))

    log_debug "[Pipeline] Issue $issue_id 正常計數: $normal_count/$PIPELINE_NORMAL_THRESHOLD"

    if (( normal_count >= PIPELINE_NORMAL_THRESHOLD )); then
      log_info "[Pipeline] Issue $issue_id 連續 $PIPELINE_NORMAL_THRESHOLD 次正常，準備關閉"

      if [[ "$PIPELINE_DRY_RUN" != "true" ]]; then
        if [[ -n "$github_number" && -n "$GITHUB_REPO" ]]; then
          close_issue "$github_number" "問題已自動解決，連續 $PIPELINE_NORMAL_THRESHOLD 次檢查正常。" 2>/dev/null || true
          notify_all "Issue #$github_number 已自動關閉" "success" 2>/dev/null || true
        fi
        state_delete_issue "$issue_id"
        ((closed_count++))
      else
        log_info "[DRY-RUN] 會關閉 Issue: $issue_id"
      fi
    fi
  done < <(state_list_issues "open" 2>/dev/null)

  if (( closed_count > 0 )); then
    log_info "[Pipeline] 已關閉 $closed_count 個 Issue"
  fi
}

# 設定 dry-run 模式
pipeline_set_dry_run() {
  local enabled="$1"
  case "${enabled,,}" in
    true|yes|1|on)  PIPELINE_DRY_RUN="true" ;;
    false|no|0|off) PIPELINE_DRY_RUN="false" ;;
  esac
}

# 設定是否使用 AI
pipeline_set_use_ai() {
  local enabled="$1"
  case "${enabled,,}" in
    true|yes|1|on)  PIPELINE_USE_AI="true" ;;
    false|no|0|off) PIPELINE_USE_AI="false" ;;
  esac
}

# 設定正常閾值
pipeline_set_normal_threshold() {
  PIPELINE_NORMAL_THRESHOLD="$1"
}

# 設定狀態回報
pipeline_set_status_report() {
  local enabled="$1"
  case "${enabled,,}" in
    true|yes|1|on)  PIPELINE_STATUS_REPORT="true" ;;
    false|no|0|off) PIPELINE_STATUS_REPORT="false" ;;
  esac
}

# 設定錯誤時回報
pipeline_set_status_report_on_error() {
  local enabled="$1"
  case "${enabled,,}" in
    true|yes|1|on)  PIPELINE_STATUS_REPORT_ON_ERROR="true" ;;
    false|no|0|off) PIPELINE_STATUS_REPORT_ON_ERROR="false" ;;
  esac
}

# 內部函式：回報狀態到 GitHub
# 用法: _pipeline_report_status "system_metrics" "alert_summary" "analysis" "trigger"
# trigger: "periodic" 定期回報, "error" 有問題時回報
_pipeline_report_status() {
  local system_metrics="${1:-{}}"
  local alert_summary="${2:-{}}"
  local analysis="${3:-{}}"
  local trigger="${4:-periodic}"

  # 檢查狀態回報功能是否存在
  if ! declare -f report_status_to_github >/dev/null 2>&1; then
    log_debug "[Pipeline] 狀態回報模組未載入"
    return 0
  fi

  # 檢查是否已啟用
  if [[ "${STATUS_REPORT_ENABLED:-false}" != "true" ]]; then
    log_debug "[Pipeline] 狀態回報未啟用"
    return 0
  fi

  if [[ "$PIPELINE_DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] 會回報狀態到 GitHub"
    return 0
  fi

  local result
  if [[ "$trigger" == "error" ]]; then
    # 有問題時立即回報
    result=$(force_report_status "$system_metrics" "$alert_summary" "$analysis" 2>&1)
  else
    # 定期回報（檢查間隔）
    result=$(conditional_report_status "$system_metrics" "$alert_summary" "$analysis" 2>&1)
  fi

  local success
  success=$(echo "$result" | jq -r '.success // .skipped // false' 2>/dev/null)
  if [[ "$success" == "true" ]]; then
    log_info "[Pipeline] 狀態已回報到 GitHub"
  else
    local skipped
    skipped=$(echo "$result" | jq -r '.skipped // false' 2>/dev/null)
    if [[ "$skipped" == "true" ]]; then
      log_debug "[Pipeline] 狀態回報已跳過（尚未到間隔時間）"
    else
      log_warn "[Pipeline] 狀態回報失敗: $(echo "$result" | jq -r '.error // "未知錯誤"' 2>/dev/null)"
    fi
  fi
}

# 外部可呼叫的狀態回報函式
# 用法: pipeline_report_status "system_metrics" "alert_summary" "analysis"
pipeline_report_status() {
  local system_metrics="${1:-{}}"
  local alert_summary="${2:-{}}"
  local analysis="${3:-{}}"

  _pipeline_report_status "$system_metrics" "$alert_summary" "$analysis" "periodic"
}
