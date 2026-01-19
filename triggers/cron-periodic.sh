#!/usr/bin/env bash
###############################################
# triggers/cron-periodic.sh
# 定期檢查觸發器
#
# 職責：
#   - 定期收集系統指標
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
source "${SCRIPT_DIR}/lib/updater.sh"

# 載入收集器
source "${SCRIPT_DIR}/collectors/system.sh"
source "${SCRIPT_DIR}/collectors/docker.sh"
source "${SCRIPT_DIR}/collectors/logs.sh"

# 載入分析器
source "${SCRIPT_DIR}/analyzers/threshold-checker.sh"
source "${SCRIPT_DIR}/analyzers/claude-analyzer.sh"

# 載入修復系統
source "${SCRIPT_DIR}/remediation/validators/safety-check.sh"
source "${SCRIPT_DIR}/remediation/executor.sh"

# 載入整合
source "${SCRIPT_DIR}/integrations/github-issues.sh"
source "${SCRIPT_DIR}/integrations/github-status.sh"

# 全域設定
CHECK_INTERVAL="${CHECK_INTERVAL:-300}"  # 5 分鐘

# 初始化
init_periodic_check() {
  # 載入設定
  local config_file="${SCRIPT_DIR}/config/config.yaml"
  if [[ -f "$config_file" ]]; then
    config_load "$config_file" || {
      log_error "無法載入設定檔"
      return 1
    }
  else
    log_warn "設定檔不存在：$config_file"
  fi

  # 初始化日誌
  log_init "${SCRIPT_DIR}/logs" "$(config_get 'log_level' 'INFO')"

  # 初始化狀態
  state_init "${SCRIPT_DIR}/state"

  # 初始化閾值
  threshold_init \
    "$(config_get_int 'thresholds.cpu_percent' 80)" \
    "$(config_get_int 'thresholds.memory_percent' 85)" \
    "$(config_get_int 'thresholds.disk_percent' 90)" \
    "$(config_get 'thresholds.load_per_cpu' '2.0')"

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

  # 初始化狀態回報
  local status_report_enabled status_report_interval status_report_on_error
  status_report_enabled=$(config_get_bool 'status_report.enabled' 'false')
  status_report_interval=$(config_get_int 'status_report.interval_minutes' 30)
  status_report_on_error=$(config_get_bool 'status_report.report_on_error' 'true')

  if [[ "$status_report_enabled" == "true" ]]; then
    status_report_init "$status_report_interval" 2>/dev/null && {
      pipeline_set_status_report "true"
      pipeline_set_status_report_on_error "$status_report_on_error"
      log_debug "狀態回報已啟用"
    }
  fi

  # 初始化自動更新
  local auto_update_enabled auto_update_branch auto_update_interval auto_update_restart
  auto_update_enabled=$(config_get_bool 'auto_update.enabled' 'false')
  auto_update_branch=$(config_get 'auto_update.branch' 'main')
  auto_update_interval=$(config_get_int 'auto_update.interval_minutes' 60)
  auto_update_restart=$(config_get_bool 'auto_update.auto_restart' 'true')

  if [[ "$auto_update_enabled" == "true" ]]; then
    updater_init "$auto_update_branch" "$auto_update_interval" 2>/dev/null && {
      updater_set_auto_restart "$auto_update_restart"
      log_debug "自動更新已啟用，分支: ${auto_update_branch}"
    }
  fi

  # 讀取檢查間隔
  local interval_minutes
  interval_minutes=$(config_get_int 'intervals.periodic_check_minutes' 5)

  # -1 表示停用
  if (( interval_minutes < 0 )); then
    log_info "定期檢查已停用（interval = $interval_minutes）"
    exit 0
  fi

  CHECK_INTERVAL=$(( interval_minutes * 60 ))

  return 0
}

# 收集所有指標並產生 alert_summary
collect_and_analyze() {
  log_info "收集系統指標..."

  # 1. 收集系統指標
  local system_metrics
  system_metrics=$(collect_all_system)

  # 2. 收集 Docker 狀態
  local docker_status=""
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    log_debug "收集 Docker 狀態..."
    docker_status=$(collect_unhealthy_containers)
  fi

  # 3. 檢查閾值
  log_debug "檢查閾值..."
  local threshold_result
  threshold_result=$(check_thresholds "$system_metrics")

  # 4. 產生警報摘要
  local alert_summary
  alert_summary=$(generate_alert_summary "$threshold_result" "$docker_status" "")

  # 輸出結果（供 pipeline 使用）
  echo "$alert_summary"
  echo "---METRICS---"
  echo "$system_metrics"
}

# 執行單次檢查
run_periodic_check() {
  local dry_run="${1:-false}"

  log_info "========== 開始定期檢查 =========="

  # 取得執行鎖
  if ! state_lock 10; then
    log_warn "無法取得執行鎖，可能有另一個檢查正在執行"
    return 1
  fi

  trap 'state_unlock' EXIT

  # 設定 pipeline dry-run 模式
  if [[ "$dry_run" == "true" ]]; then
    pipeline_set_dry_run "true"
    github_set_dry_run "true"
    set_remediation_dry_run "true"
  fi

  # 收集並分析
  local result
  result=$(collect_and_analyze)

  # 分離 alert_summary 和 metrics
  local alert_summary system_metrics
  alert_summary=$(echo "$result" | sed -n '1,/^---METRICS---$/p' | head -n -1)
  system_metrics=$(echo "$result" | sed -n '/^---METRICS---$/,$ p' | tail -n +2)

  local issue_count
  issue_count=$(echo "$alert_summary" | jq -r '.issue_count // 0')
  log_info "檢查結果: $issue_count 個問題"

  # 呼叫 pipeline 處理
  pipeline_process "$alert_summary" "$system_metrics" "periodic"

  # 清理過期冷卻
  state_cleanup_cooldowns

  # 日誌輪替檢查
  log_rotate_if_needed

  # 檢查自動更新
  if [[ "$UPDATER_ENABLED" == "true" ]]; then
    if should_check_update; then
      log_info "檢查是否有新版本..."
      mark_update_checked
      auto_update_if_needed || log_warn "自動更新檢查失敗"
    fi
  fi

  log_info "========== 定期檢查完成 =========="

  state_unlock
  trap - EXIT

  return 0
}

# 主函式
main() {
  parse_args "$@"

  local dry_run="${ARG_dry_run:-}"
  local once="${ARG_once:-}"

  # 初始化
  init_periodic_check || exit 1

  if [[ -n "$once" ]]; then
    # 單次執行
    run_periodic_check "$dry_run"
  else
    # 持續執行（daemon 模式）
    log_info "啟動定期檢查 daemon（間隔: ${CHECK_INTERVAL}s）"

    while true; do
      run_periodic_check "$dry_run" || true
      log_info "等待 ${CHECK_INTERVAL} 秒..."
      sleep "$CHECK_INTERVAL"
    done
  fi
}

# 如果直接執行此腳本
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
