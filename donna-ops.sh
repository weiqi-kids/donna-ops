#!/usr/bin/env bash
###############################################
# donna-ops.sh
# Donna-Ops 自動化維運框架主入口
#
# 子命令：
#   check    - 執行單次系統檢查
#   daemon   - 啟動背景服務
#   diagnose - 執行完整診斷
#   status   - 顯示目前狀態
#
# 用法：
#   ./donna-ops.sh check [--dry-run]
#   ./donna-ops.sh daemon [--periodic] [--alert-poller]
#   ./donna-ops.sh diagnose [--full] [--ai]
#   ./donna-ops.sh status
###############################################

set -euo pipefail

# 版本
VERSION="1.0.0"

# 取得腳本目錄（支援符號連結）
_source="${BASH_SOURCE[0]}"
while [[ -L "$_source" ]]; do
  _dir="$(cd -P "$(dirname "$_source")" && pwd)"
  _source="$(readlink "$_source")"
  [[ "$_source" != /* ]] && _source="$_dir/$_source"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_source")" && pwd)"
unset _source _dir
export SCRIPT_DIR

# 顯示幫助
show_help() {
  cat <<EOF
Donna-Ops v${VERSION} - 自動化維運框架

用法: donna-ops.sh <command> [options]

命令:
  check       執行單次系統檢查
  daemon      啟動背景服務（定期檢查 + 警報輪詢）
  diagnose    執行完整診斷
  status      顯示目前狀態
  version     顯示版本

check 選項:
  --dry-run   模擬執行，不實際執行修復

daemon 選項:
  --periodic      只啟動定期檢查
  --alert-poller  只啟動警報輪詢
  --foreground    前景執行

diagnose 選項:
  --full      完整診斷（包含日誌分析）
  --ai        使用 Claude AI 分析
  --output    輸出格式 (json|text)

status 選項:
  --json      JSON 格式輸出
  --issues    只顯示目前問題
  --report    回報目前狀態到 GitHub

範例:
  donna-ops.sh check                  # 單次檢查
  donna-ops.sh check --dry-run        # 模擬檢查
  donna-ops.sh daemon --foreground    # 前景執行 daemon
  donna-ops.sh diagnose --ai          # AI 輔助診斷
  donna-ops.sh status                 # 顯示狀態

EOF
}

# 載入核心模組
load_modules() {
  source "${SCRIPT_DIR}/lib/core.sh"
  source "${SCRIPT_DIR}/lib/args.sh"
  source "${SCRIPT_DIR}/lib/config.sh"
  source "${SCRIPT_DIR}/lib/logging.sh"
  source "${SCRIPT_DIR}/lib/state.sh"
  source "${SCRIPT_DIR}/lib/notify.sh"
}

# 載入收集器
load_collectors() {
  source "${SCRIPT_DIR}/collectors/system.sh"
  source "${SCRIPT_DIR}/collectors/docker.sh"
  source "${SCRIPT_DIR}/collectors/logs.sh"
  source "${SCRIPT_DIR}/collectors/linode.sh"
}

# 載入分析器
load_analyzers() {
  source "${SCRIPT_DIR}/analyzers/threshold-checker.sh"
  source "${SCRIPT_DIR}/analyzers/claude-analyzer.sh"
}

# 載入修復系統
load_remediation() {
  source "${SCRIPT_DIR}/remediation/validators/safety-check.sh"
  source "${SCRIPT_DIR}/remediation/executor.sh"
}

# 載入整合
load_integrations() {
  source "${SCRIPT_DIR}/integrations/github-issues.sh"
  source "${SCRIPT_DIR}/integrations/github-status.sh"
  source "${SCRIPT_DIR}/integrations/linode-alerts.sh"
}

# 初始化
initialize() {
  # 載入設定
  local config_file="${SCRIPT_DIR}/config/config.yaml"
  if [[ -f "$config_file" ]]; then
    config_load "$config_file" || {
      echo "警告: 無法載入設定檔" >&2
    }
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

  # 初始化 Linode
  local api_token instance_id
  api_token=$(config_get 'linode_api_token')
  instance_id=$(config_get 'linode_instance_id')
  if [[ -n "$api_token" ]]; then
    linode_init "$api_token" "$instance_id" 2>/dev/null || true
  fi

  # 初始化 GitHub（支援自動偵測）
  local github_repo
  github_repo=$(config_get_github_repo)
  if [[ -n "$github_repo" ]]; then
    github_init "$github_repo" 2>/dev/null || true
    log_debug "GitHub repo: $github_repo"
  fi

  # 初始化通知
  notify_init \
    "$(config_get 'notifications.slack_webhook')" \
    "$(config_get 'notifications.telegram_bot_token')" \
    "$(config_get 'notifications.telegram_chat_id')"

  # 初始化修復執行器
  executor_init "${SCRIPT_DIR}/remediation/actions"

  # 初始化狀態回報
  local status_report_enabled status_report_interval status_report_on_error
  status_report_enabled=$(config_get_bool 'status_report.enabled' 'false')
  status_report_interval=$(config_get_int 'status_report.interval_minutes' 30)
  status_report_on_error=$(config_get_bool 'status_report.report_on_error' 'true')

  if [[ "$status_report_enabled" == "true" && -n "$github_repo" ]]; then
    status_report_init "$status_report_interval" 2>/dev/null && {
      pipeline_set_status_report "true"
      pipeline_set_status_report_on_error "$status_report_on_error"
      log_debug "狀態回報已啟用，間隔: ${status_report_interval} 分鐘"
    }
  fi
}

# check 命令
cmd_check() {
  local dry_run="${ARG_dry_run:-}"

  log_info "========== 開始系統檢查 =========="

  if [[ -n "$dry_run" ]]; then
    log_info "模式: Dry-run（不執行實際修復）"
    set_remediation_dry_run "true"
    github_set_dry_run "true"
  fi

  # 收集系統指標
  log_info "收集系統指標..."
  local system_metrics
  system_metrics=$(collect_all_system)

  echo ""
  echo "=== 系統摘要 ==="
  echo "$system_metrics" | jq '{
    cpu: .cpu.usage_percent,
    memory: .memory.usage_percent,
    load: .load.load_1m,
    top_cpu: [.top_processes_cpu[:3][] | {cmd: .command, cpu: .cpu_percent}]
  }'

  # 收集 Docker 狀態
  local docker_status=""
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    log_info "收集 Docker 狀態..."
    docker_status=$(collect_unhealthy_containers)
    local unhealthy_count
    unhealthy_count=$(echo "$docker_status" | jq '.unhealthy | length')
    echo ""
    echo "=== Docker 狀態 ==="
    echo "不健康容器: $unhealthy_count"
    if (( unhealthy_count > 0 )); then
      echo "$docker_status" | jq '.unhealthy[] | "  - \(.name): \(.reason)"' -r
    fi
  fi

  # 檢查閾值
  log_info "檢查閾值..."
  local threshold_result
  threshold_result=$(check_thresholds "$system_metrics")

  echo ""
  echo "=== 閾值檢查 ==="
  local has_violations
  has_violations=$(echo "$threshold_result" | jq -r '.has_violations')
  if [[ "$has_violations" == "true" ]]; then
    echo "狀態: 有違規"
    echo "$threshold_result" | jq '.violations[] | "  - \(.metric): \(.current)% (閾值: \(.threshold)%)"' -r
  else
    echo "狀態: 正常"
  fi

  # 產生警報摘要
  local alert_summary
  alert_summary=$(generate_alert_summary "$threshold_result" "$docker_status" "")

  local issue_count max_severity
  issue_count=$(echo "$alert_summary" | jq -r '.issue_count')
  max_severity=$(echo "$alert_summary" | jq -r '.max_severity')

  echo ""
  echo "=== 檢查結果 ==="
  echo "問題數量: $issue_count"
  echo "最高嚴重度: $max_severity"

  if (( issue_count > 0 )); then
    echo ""
    echo "建議的修復動作:"
    local actions
    actions=$(get_suggested_actions "$alert_summary")
    echo "$actions" | jq '.[] | "  - \(.action): \(.reason)"' -r
  fi

  log_info "========== 檢查完成 =========="
}

# daemon 命令
cmd_daemon() {
  local periodic_only="${ARG_periodic:-}"
  local poller_only="${ARG_alert_poller:-}"
  local foreground="${ARG_foreground:-}"

  # 檢查間隔設定（-1 表示停用）
  local periodic_interval poller_interval
  periodic_interval=$(config_get_int 'intervals.periodic_check_minutes' 5)
  poller_interval=$(config_get_int 'intervals.alert_poll_seconds' 60)

  local enable_periodic="true"
  local enable_poller="true"

  if (( periodic_interval < 0 )); then
    enable_periodic="false"
    log_info "定期檢查已停用（interval = $periodic_interval）"
  fi

  if (( poller_interval < 0 )); then
    enable_poller="false"
    log_info "警報輪詢已停用（interval = $poller_interval）"
  fi

  # 如果兩者都停用
  if [[ "$enable_periodic" == "false" && "$enable_poller" == "false" ]]; then
    log_error "定期檢查和警報輪詢都已停用，無法啟動 daemon"
    exit 1
  fi

  log_info "啟動 Donna-Ops Daemon..."

  if [[ -n "$periodic_only" ]]; then
    if [[ "$enable_periodic" == "false" ]]; then
      log_error "定期檢查已停用"
      exit 1
    fi
    log_info "只啟動定期檢查..."
    exec "${SCRIPT_DIR}/triggers/cron-periodic.sh"
  elif [[ -n "$poller_only" ]]; then
    if [[ "$enable_poller" == "false" ]]; then
      log_error "警報輪詢已停用"
      exit 1
    fi
    log_info "只啟動警報輪詢..."
    exec "${SCRIPT_DIR}/triggers/alert-poller.sh"
  else
    # 啟動有啟用的服務
    local pids=()

    if [[ -n "$foreground" ]]; then
      # 前景執行
      if [[ "$enable_periodic" == "true" ]]; then
        "${SCRIPT_DIR}/triggers/cron-periodic.sh" &
        pids+=($!)
        log_info "定期檢查 PID: ${pids[-1]}"
      fi

      if [[ "$enable_poller" == "true" ]]; then
        "${SCRIPT_DIR}/triggers/alert-poller.sh" &
        pids+=($!)
        log_info "警報輪詢 PID: ${pids[-1]}"
      fi

      # 等待任一結束
      wait -n
      log_warn "子程序結束，停止 daemon"
      for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null || true
      done
    else
      # 背景執行
      if [[ "$enable_periodic" == "true" ]]; then
        nohup "${SCRIPT_DIR}/triggers/cron-periodic.sh" >> "${SCRIPT_DIR}/logs/periodic.log" 2>&1 &
        echo $! > "${SCRIPT_DIR}/state/periodic.pid"
        echo "定期檢查 PID: $(cat "${SCRIPT_DIR}/state/periodic.pid")"
      fi

      if [[ "$enable_poller" == "true" ]]; then
        nohup "${SCRIPT_DIR}/triggers/alert-poller.sh" >> "${SCRIPT_DIR}/logs/poller.log" 2>&1 &
        echo $! > "${SCRIPT_DIR}/state/poller.pid"
        echo "警報輪詢 PID: $(cat "${SCRIPT_DIR}/state/poller.pid")"
      fi

      echo ""
      echo "Daemon 已啟動"
      echo "查看日誌: tail -f ${SCRIPT_DIR}/logs/donna-ops.log"
    fi
  fi
}

# diagnose 命令
cmd_diagnose() {
  local full="${ARG_full:-}"
  local use_ai="${ARG_ai:-}"
  local output="${ARG_output:-text}"

  log_info "========== 開始診斷 =========="

  # 收集所有資訊
  log_info "收集系統指標..."
  local system_metrics
  system_metrics=$(collect_all_system)

  log_info "收集 Docker 狀態..."
  local docker_summary=""
  local docker_health=""
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker_summary=$(collect_docker_summary)
    docker_health=$(collect_docker_health)
  fi

  local log_errors=""
  local linode_status=""
  local linode_alerts=""

  if [[ -n "$full" ]]; then
    log_info "收集日誌錯誤..."
    log_errors=$(collect_error_summary "1 hour ago" 2>/dev/null || echo "{}")

    if [[ -n "$LINODE_API_TOKEN" ]]; then
      log_info "收集 Linode 狀態..."
      linode_status=$(get_linode_status 2>/dev/null || echo "{}")
      linode_alerts=$(poll_linode_alerts 2>/dev/null || echo "{}")
    fi
  fi

  # 檢查閾值
  local threshold_result
  threshold_result=$(check_thresholds "$system_metrics")

  # 產生警報摘要
  local docker_unhealthy=""
  if [[ -n "$docker_health" ]]; then
    docker_unhealthy=$(collect_unhealthy_containers 2>/dev/null || echo "{}")
  fi

  local alert_summary
  alert_summary=$(generate_alert_summary "$threshold_result" "$docker_unhealthy" "$linode_alerts")

  # AI 分析
  local analysis=""
  if [[ -n "$use_ai" ]]; then
    if claude_available; then
      log_info "使用 Claude AI 分析..."
      local log_samples
      log_samples=$(echo "$log_errors" | jq -r '.sample_errors[].message' 2>/dev/null | head -20)
      analysis=$(analyze_with_claude "$alert_summary" "$system_metrics" "$log_samples" 2>/dev/null)
    else
      log_warn "Claude CLI 不可用，使用規則分析"
      analysis=$(quick_analysis "$alert_summary")
    fi
  else
    analysis=$(quick_analysis "$alert_summary")
  fi

  # 輸出
  if [[ "$output" == "json" ]]; then
    cat <<EOF
{
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "system": $system_metrics,
  "docker": ${docker_summary:-null},
  "threshold_check": $threshold_result,
  "alert_summary": $alert_summary,
  "analysis": $analysis,
  "linode": ${linode_status:-null},
  "errors": ${log_errors:-null}
}
EOF
  else
    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║         Donna-Ops 診斷報告             ║"
    echo "╚════════════════════════════════════════╝"
    echo ""
    echo "主機: $(hostname)"
    echo "時間: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    echo "【系統資源】"
    echo "  CPU 使用率: $(echo "$system_metrics" | jq -r '.cpu.usage_percent')%"
    echo "  記憶體使用: $(echo "$system_metrics" | jq -r '.memory.usage_percent')%"
    echo "  系統負載: $(echo "$system_metrics" | jq -r '.load.load_1m')"
    echo ""

    echo "【磁碟使用】"
    echo "$system_metrics" | jq -r '.disks[] | "  \(.mount): \(.usage_percent)%"'
    echo ""

    if [[ -n "$docker_summary" && "$docker_summary" != "null" ]]; then
      echo "【Docker】"
      echo "  運行中容器: $(echo "$docker_summary" | jq -r '.containers.running')"
      echo "  不健康容器: $(echo "$docker_summary" | jq -r '.containers.unhealthy')"
      echo ""
    fi

    echo "【檢查結果】"
    local issue_count
    issue_count=$(echo "$alert_summary" | jq -r '.issue_count')
    if (( issue_count > 0 )); then
      echo "  狀態: 發現 $issue_count 個問題"
      echo "  最高嚴重度: $(echo "$alert_summary" | jq -r '.max_severity')"
      echo ""
      echo "  問題清單:"
      echo "$alert_summary" | jq -r '.issues[] | "    - [\(.severity)] \(.type): \(.metric // .container // .alert_type)"'
    else
      echo "  狀態: 正常"
    fi
    echo ""

    echo "【分析】"
    echo "  嚴重度: $(echo "$analysis" | jq -r '.severity')"
    echo "  診斷: $(echo "$analysis" | jq -r '.diagnosis')"
    if [[ -n "$use_ai" ]]; then
      echo "  緊急程度: $(echo "$analysis" | jq -r '.urgency')"
    fi
    echo ""

    local rec_count
    rec_count=$(echo "$analysis" | jq '.recommendations | length')
    if (( rec_count > 0 )); then
      echo "【建議動作】"
      echo "$analysis" | jq -r '.recommendations[] | "  - \(.action): \(.description) [風險: \(.risk_level)]"'
    fi
    echo ""
  fi

  log_info "========== 診斷完成 =========="
}

# status 命令
cmd_status() {
  local json_output="${ARG_json:-}"
  local issues_only="${ARG_issues:-}"
  local do_report="${ARG_report:-}"

  # 如果要回報狀態到 GitHub
  if [[ -n "$do_report" ]]; then
    _cmd_status_report
    return $?
  fi

  # 讀取設定
  local periodic_interval poller_interval
  periodic_interval=$(config_get_int 'intervals.periodic_check_minutes' 5)
  poller_interval=$(config_get_int 'intervals.alert_poll_seconds' 60)

  local periodic_disabled="false"
  local poller_disabled="false"
  [[ $periodic_interval -lt 0 ]] && periodic_disabled="true"
  [[ $poller_interval -lt 0 ]] && poller_disabled="true"

  # 讀取狀態
  local daemon_running="false"
  local periodic_running="false"
  local poller_running="false"

  # 方法 1: 檢查 PID 檔案
  if [[ -f "${SCRIPT_DIR}/state/periodic.pid" ]]; then
    local pid
    pid=$(cat "${SCRIPT_DIR}/state/periodic.pid")
    if kill -0 "$pid" 2>/dev/null; then
      periodic_running="true"
      daemon_running="true"
    fi
  fi

  if [[ -f "${SCRIPT_DIR}/state/poller.pid" ]]; then
    local pid
    pid=$(cat "${SCRIPT_DIR}/state/poller.pid")
    if kill -0 "$pid" 2>/dev/null; then
      poller_running="true"
      daemon_running="true"
    fi
  fi

  # 方法 2: 檢查 systemd 服務狀態（前景模式）
  if [[ "$daemon_running" == "false" ]] && command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet donna-ops 2>/dev/null; then
      daemon_running="true"
      # 檢查實際進程
      if pgrep -f "cron-periodic.sh" >/dev/null 2>&1; then
        periodic_running="true"
      fi
      if pgrep -f "alert-poller.sh" >/dev/null 2>&1; then
        poller_running="true"
      fi
    fi
  fi

  # 方法 3: 直接檢查進程（fallback）
  if [[ "$daemon_running" == "false" ]]; then
    if pgrep -f "donna-ops.sh daemon" >/dev/null 2>&1; then
      daemon_running="true"
      if pgrep -f "cron-periodic.sh" >/dev/null 2>&1; then
        periodic_running="true"
      fi
      if pgrep -f "alert-poller.sh" >/dev/null 2>&1; then
        poller_running="true"
      fi
    fi
  fi

  # 讀取問題
  local issues="[]"
  local issue_count=0
  if [[ -d "${SCRIPT_DIR}/state/issues" ]]; then
    while IFS= read -r issue_file; do
      [[ -f "$issue_file" ]] || continue
      local issue_data
      issue_data=$(cat "$issue_file")
      issues=$(echo "$issues" | jq --argjson i "$issue_data" '. + [$i]')
      ((issue_count++))
    done < <(ls "${SCRIPT_DIR}/state/issues"/*.json 2>/dev/null)
  fi

  if [[ -n "$json_output" ]]; then
    cat <<EOF
{
  "daemon_running": $daemon_running,
  "periodic": {
    "running": $periodic_running,
    "disabled": $periodic_disabled
  },
  "poller": {
    "running": $poller_running,
    "disabled": $poller_disabled
  },
  "active_issues": $issue_count,
  "issues": $issues
}
EOF
  else
    if [[ -n "$issues_only" ]]; then
      echo "目前問題 ($issue_count 個):"
      if (( issue_count > 0 )); then
        echo "$issues" | jq -r '.[] | "  [\(.status)] \(.issue_id) (GitHub #\(.github_number // "N/A"))"'
      else
        echo "  （無）"
      fi
    else
      echo "╔════════════════════════════════════════╗"
      echo "║         Donna-Ops 狀態                 ║"
      echo "╚════════════════════════════════════════╝"
      echo ""
      echo "【服務狀態】"
      if [[ "$periodic_disabled" == "true" ]]; then
        echo "  定期檢查: 已停用 ○"
      elif [[ "$periodic_running" == "true" ]]; then
        echo "  定期檢查: 運行中 ✓"
      else
        echo "  定期檢查: 已停止 ✗"
      fi
      if [[ "$poller_disabled" == "true" ]]; then
        echo "  警報輪詢: 已停用 ○"
      elif [[ "$poller_running" == "true" ]]; then
        echo "  警報輪詢: 運行中 ✓"
      else
        echo "  警報輪詢: 已停止 ✗"
      fi
      echo ""
      echo "【目前問題】"
      if (( issue_count > 0 )); then
        echo "  共 $issue_count 個問題:"
        echo "$issues" | jq -r '.[] | "    - [\(.status)] \(.issue_id)"'
      else
        echo "  無進行中的問題 ✓"
      fi
      echo ""
      echo "【日誌位置】"
      echo "  ${SCRIPT_DIR}/logs/donna-ops.log"
    fi
  fi
}

# 回報狀態到 GitHub
_cmd_status_report() {
  echo "正在收集系統狀態並回報到 GitHub..."
  echo ""

  # 檢查 GitHub 設定
  if [[ -z "$GITHUB_REPO" ]]; then
    echo "錯誤: GitHub 未設定，請先配置 config.yaml 中的 github_repo"
    return 1
  fi

  # 初始化狀態回報
  if ! status_report_init 30 2>/dev/null; then
    echo "錯誤: 無法初始化狀態回報"
    return 1
  fi

  # 收集系統指標
  echo "收集系統指標..."
  local system_metrics
  system_metrics=$(collect_all_system 2>/dev/null || collect_quick_metrics)

  # 檢查閾值
  echo "檢查閾值..."
  local threshold_result
  threshold_result=$(check_thresholds "$system_metrics" 2>/dev/null || echo '{"has_violations":false,"violations":[]}')

  # 收集 Docker 狀態
  local docker_status=""
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "收集 Docker 狀態..."
    docker_status=$(collect_unhealthy_containers 2>/dev/null || echo '{}')
  fi

  # 產生警報摘要
  local alert_summary
  alert_summary=$(generate_alert_summary "$threshold_result" "$docker_status" "" 2>/dev/null || echo '{"issue_count":0,"max_severity":"ok","issues":[]}')

  # 快速分析
  local analysis
  analysis=$(quick_analysis "$alert_summary" 2>/dev/null || echo '{}')

  # 回報狀態
  echo "回報狀態到 GitHub..."
  local result
  result=$(force_report_status "$system_metrics" "$alert_summary" "$analysis")

  local success
  success=$(echo "$result" | jq -r '.success // false' 2>/dev/null)

  echo ""
  if [[ "$success" == "true" ]]; then
    local issue_number
    issue_number=$(echo "$result" | jq -r '.issue_number')
    echo "✓ 狀態已成功回報到 GitHub Issue #$issue_number"
    echo ""
    echo "查看狀態儀表板:"
    echo "  https://github.com/${GITHUB_REPO}/issues/${issue_number}"
  else
    local error
    error=$(echo "$result" | jq -r '.error // "未知錯誤"' 2>/dev/null)
    echo "✗ 狀態回報失敗: $error"
    return 1
  fi
}

# 主函式
main() {
  # 解析命令
  local command="${1:-help}"
  shift || true

  case "$command" in
    check|daemon|diagnose|status)
      # 載入模組
      load_modules
      load_collectors
      load_analyzers
      load_remediation
      load_integrations

      # 解析參數
      parse_args "$@"

      # 初始化
      initialize

      # 執行命令
      "cmd_${command}"
      ;;
    version|-v|--version)
      echo "Donna-Ops v${VERSION}"
      ;;
    help|-h|--help)
      show_help
      ;;
    *)
      echo "未知命令: $command"
      echo ""
      show_help
      exit 1
      ;;
  esac
}

# 執行
main "$@"
