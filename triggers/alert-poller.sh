#!/usr/bin/env bash
###############################################
# triggers/alert-poller.sh
# Linode Alert 輪詢器
#
# 職責：
#   - 輪詢 Linode Alert API
#   - 偵測新警報
#   - 產生 alert_summary
#   - 呼叫 pipeline 處理
###############################################

set -euo pipefail

# 取得腳本目錄
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 載入核心模組
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/args.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/state.sh"
source "${SCRIPT_DIR}/lib/notify.sh"
source "${SCRIPT_DIR}/lib/pipeline.sh"

# 載入收集器
source "${SCRIPT_DIR}/collectors/system.sh"
source "${SCRIPT_DIR}/collectors/linode.sh"
source "${SCRIPT_DIR}/collectors/logs.sh"

# 載入分析器
source "${SCRIPT_DIR}/analyzers/threshold-checker.sh"
source "${SCRIPT_DIR}/analyzers/claude-analyzer.sh"

# 載入修復系統
source "${SCRIPT_DIR}/remediation/validators/safety-check.sh"
source "${SCRIPT_DIR}/remediation/executor.sh"

# 載入整合
source "${SCRIPT_DIR}/integrations/github-issues.sh"
source "${SCRIPT_DIR}/integrations/linode-alerts.sh"

# 全域設定
POLL_INTERVAL="${POLL_INTERVAL:-60}"  # 60 秒

# 上一次的警報資料
PREVIOUS_ALERTS=""

# 初始化
init_alert_poller() {
  # 載入設定
  local config_file="${SCRIPT_DIR}/config/config.yaml"
  if [[ -f "$config_file" ]]; then
    config_load "$config_file" || {
      log_error "無法載入設定檔"
      return 1
    }
  else
    log_error "設定檔不存在：$config_file"
    return 1
  fi

  # 初始化日誌
  log_init "${SCRIPT_DIR}/logs" "$(config_get 'log_level' 'INFO')"

  # 初始化狀態
  state_init "${SCRIPT_DIR}/state"

  # 初始化 Linode
  local api_token instance_id
  api_token=$(config_get 'linode_api_token')
  instance_id=$(config_get 'linode_instance_id')

  if [[ -z "$api_token" ]]; then
    log_error "缺少 linode_api_token 設定"
    return 1
  fi

  linode_init "$api_token" "$instance_id" || {
    log_error "Linode 初始化失敗"
    return 1
  }

  # 初始化 GitHub
  local github_repo
  github_repo=$(config_get 'github_repo')
  if [[ -n "$github_repo" ]]; then
    github_init "$github_repo" || log_warn "GitHub 初始化失敗"
  fi

  # 初始化通知
  notify_init \
    "$(config_get 'notifications.slack_webhook')" \
    "$(config_get 'notifications.telegram_bot_token')" \
    "$(config_get 'notifications.telegram_chat_id')"

  # 初始化修復執行器
  executor_init "${SCRIPT_DIR}/remediation/actions"

  # 初始化 Pipeline 設定
  pipeline_set_normal_threshold "$(config_get_int 'issues.normal_threshold' 3)"
  if [[ "$(config_get_bool 'claude.default_ai' 'false')" == "true" ]]; then
    pipeline_set_use_ai "true"
  fi

  # 讀取輪詢間隔
  POLL_INTERVAL=$(config_get_int 'intervals.alert_poll_seconds' 60)

  # -1 表示停用
  if (( POLL_INTERVAL < 0 )); then
    log_info "警報輪詢已停用（interval = $POLL_INTERVAL）"
    exit 0
  fi

  return 0
}

# 將 Linode 警報轉換為標準 alert_summary 格式
convert_to_alert_summary() {
  local alerts_json="$1"

  local alert_count
  alert_count=$(echo "$alerts_json" | jq '.new_count // 0')

  if (( alert_count == 0 )); then
    # 沒有新警報
    cat <<EOF
{
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "hostname": "$(hostname)",
  "issue_count": 0,
  "max_severity": "ok",
  "summary": "沒有新警報",
  "issues": []
}
EOF
    return 0
  fi

  # 轉換警報為 issues 格式
  local issues="[]"
  local max_severity="minor"

  while IFS= read -r alert; do
    [[ -z "$alert" || "$alert" == "null" ]] && continue

    local alert_type severity message normalized_type
    alert_type=$(echo "$alert" | jq -r '.type')
    severity=$(echo "$alert" | jq -r '.severity // "minor"')
    message=$(echo "$alert" | jq -r '.message // ""')
    normalized_type=$(echo "$alert" | jq -r '.normalized_type // .type')

    # 映射嚴重度
    local mapped_severity
    case "$severity" in
      critical) mapped_severity="critical" ;;
      major)    mapped_severity="warning" ;;
      *)        mapped_severity="minor" ;;
    esac

    # 更新最大嚴重度
    case "$mapped_severity" in
      critical)
        max_severity="critical"
        ;;
      warning)
        [[ "$max_severity" != "critical" ]] && max_severity="warning"
        ;;
    esac

    issues=$(echo "$issues" | jq \
      --arg type "linode" \
      --arg alert_type "$normalized_type" \
      --arg message "$message" \
      --arg severity "$mapped_severity" \
      '. + [{
        "type": $type,
        "alert_type": $alert_type,
        "message": $message,
        "severity": $severity
      }]')
  done < <(echo "$alerts_json" | jq -c '.new_alerts[]' 2>/dev/null)

  # 產生摘要文字
  local summary_lines=()
  while IFS= read -r issue; do
    [[ -z "$issue" || "$issue" == "null" ]] && continue
    local alert_type message
    alert_type=$(echo "$issue" | jq -r '.alert_type')
    message=$(echo "$issue" | jq -r '.message')
    summary_lines+=("Linode: $alert_type - $message")
  done < <(echo "$issues" | jq -c '.[]' 2>/dev/null)

  local summary_text
  summary_text=$(printf '%s\n' "${summary_lines[@]}")

  cat <<EOF
{
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "hostname": "$(hostname)",
  "issue_count": $alert_count,
  "max_severity": "$max_severity",
  "summary": $(echo "$summary_text" | jq -Rs '.'),
  "issues": $issues
}
EOF
}

# 執行單次輪詢
poll_once() {
  local dry_run="${1:-false}"

  log_debug "輪詢 Linode 警報..."

  # 設定 pipeline dry-run 模式
  if [[ "$dry_run" == "true" ]]; then
    pipeline_set_dry_run "true"
    github_set_dry_run "true"
    set_remediation_dry_run "true"
  fi

  # 取得警報
  local current_alerts
  current_alerts=$(fetch_active_alerts)

  local total_count
  total_count=$(echo "$current_alerts" | jq '.alert_count // 0')
  log_debug "取得 $total_count 個警報"

  # 偵測新警報
  local new_alerts_result
  if [[ -n "$PREVIOUS_ALERTS" ]]; then
    new_alerts_result=$(detect_new_alerts "$current_alerts" "$PREVIOUS_ALERTS")
  else
    # 第一次執行，所有都是新的（但標記為已處理，避免重複）
    new_alerts_result="{\"new_count\": 0, \"new_alerts\": []}"
    log_info "首次執行，記錄目前警報狀態"
  fi

  # 更新上一次的警報資料
  PREVIOUS_ALERTS="$current_alerts"

  local new_count
  new_count=$(echo "$new_alerts_result" | jq '.new_count // 0')

  if (( new_count > 0 )); then
    log_info "偵測到 $new_count 個新警報！"

    # 轉換為標準 alert_summary 格式
    local alert_summary
    alert_summary=$(convert_to_alert_summary "$new_alerts_result")

    # 收集系統指標（供診斷用）
    local system_metrics
    system_metrics=$(collect_all_system 2>/dev/null || echo "{}")

    # 呼叫 pipeline 處理
    pipeline_process "$alert_summary" "$system_metrics" "linode"
  else
    log_debug "沒有新警報"

    # 即使沒有新警報，也要檢查是否有可以關閉的 Issue
    # 產生空的 alert_summary
    local empty_summary
    empty_summary=$(cat <<EOF
{
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "hostname": "$(hostname)",
  "issue_count": 0,
  "max_severity": "ok",
  "summary": "沒有警報",
  "issues": []
}
EOF
)
    # 只檢查是否有可關閉的 Issue（不做其他處理）
    pipeline_process "$empty_summary" "" "linode"
  fi

  return 0
}

# 主函式
main() {
  parse_args "$@"

  local dry_run="${ARG_dry_run:-}"
  local once="${ARG_once:-}"

  # 初始化
  init_alert_poller || exit 1

  if [[ -n "$once" ]]; then
    # 單次執行
    log_info "執行單次輪詢..."
    poll_once "$dry_run"
  else
    # 持續執行（daemon 模式）
    log_info "啟動 Linode Alert 輪詢器（間隔: ${POLL_INTERVAL}s）"

    while true; do
      poll_once "$dry_run" || {
        log_warn "輪詢失敗，將在下次重試"
      }
      sleep "$POLL_INTERVAL"
    done
  fi
}

# 如果直接執行此腳本
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
