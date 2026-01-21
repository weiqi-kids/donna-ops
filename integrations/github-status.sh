#!/usr/bin/env bash
###############################################
# integrations/github-status.sh
# GitHub 狀態回報模組
#
# 功能：
#   - 使用固定的 GitHub Issue 作為狀態儀表板
#   - 每台主機定期回報健康狀態
#   - 支援多主機狀態追蹤
#
# 函式：
#   status_report_init()          初始化狀態回報
#   get_or_create_status_issue()  取得或建立狀態 Issue
#   report_status_to_github()     回報狀態到 GitHub
#   format_status_report()        格式化狀態報告
###############################################

if [[ -n "${INTEGRATION_GITHUB_STATUS_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
INTEGRATION_GITHUB_STATUS_SH_LOADED=1

# 狀態回報設定
declare -g STATUS_ISSUE_NUMBER=""
declare -g STATUS_REPORT_INTERVAL=30  # 分鐘

# 狀態標籤
readonly STATUS_ISSUE_LABEL="donna-ops-status"
readonly STATUS_ISSUE_TITLE="[Donna-Ops] 主機狀態儀表板"

# 初始化狀態回報
# 用法: status_report_init [interval_minutes]
status_report_init() {
  local interval="${1:-30}"

  STATUS_REPORT_INTERVAL="$interval"

  if [[ -z "$GITHUB_REPO" ]]; then
    echo "WARN: GITHUB_REPO 未設定，狀態回報將無法運作" >&2
    return 1
  fi

  # 檢查 gh CLI
  if ! command -v gh >/dev/null 2>&1; then
    echo "WARN: gh CLI 未安裝，狀態回報將無法運作" >&2
    return 1
  fi

  if ! gh auth status >/dev/null 2>&1; then
    echo "WARN: gh CLI 未認證，狀態回報將無法運作" >&2
    return 1
  fi

  return 0
}

# 內部函式：呼叫 gh CLI（支援重試）
_gh_status_retry() {
  if declare -f retry_api_call >/dev/null 2>&1; then
    retry_api_call gh "$@"
  else
    gh "$@"
  fi
}

# 取得或建立狀態 Issue
# 用法: get_or_create_status_issue
# 輸出: Issue 編號
get_or_create_status_issue() {
  if [[ -z "$GITHUB_REPO" ]]; then
    echo ""
    return 1
  fi

  # 搜尋現有的狀態 Issue
  local existing
  existing=$(_gh_status_retry issue list \
    --repo "$GITHUB_REPO" \
    --state open \
    --label "$STATUS_ISSUE_LABEL" \
    --json number,title \
    --limit 1 \
    2>/dev/null)

  if [[ -n "$existing" && "$existing" != "[]" ]]; then
    local issue_number
    issue_number=$(echo "$existing" | jq -r '.[0].number')
    echo "$issue_number"
    return 0
  fi

  # 建立新的狀態 Issue
  local body
  body=$(cat <<'EOF'
# 🖥️ Donna-Ops 主機狀態儀表板

此 Issue 用於追蹤所有部署 Donna-Ops 主機的運行狀態。

## 📊 狀態說明

| 狀態 | 說明 |
|------|------|
| ✅ 正常 | 系統運行正常，無警報 |
| ⚠️ 警告 | 有輕微問題，需要關注 |
| 🔴 異常 | 有嚴重問題，需要處理 |
| ⏸️ 離線 | 主機離線或未回報 |

## 🔄 自動更新

各主機會定期回報狀態（預設每 30 分鐘）。每個回報會以留言形式更新。

---
*此 Issue 由 Donna-Ops 自動管理，請勿手動關閉*
EOF
)

  # 建立 Issue
  local result
  result=$(_gh_status_retry issue create \
    --repo "$GITHUB_REPO" \
    --title "$STATUS_ISSUE_TITLE" \
    --body "$body" \
    --label "$STATUS_ISSUE_LABEL,donna-ops,auto-generated" \
    2>&1)

  if [[ $? -ne 0 ]]; then
    echo "ERROR: 建立狀態 Issue 失敗: $result" >&2
    echo ""
    return 1
  fi

  # 解析 Issue 編號
  local issue_number
  issue_number=$(echo "$result" | grep -oE '[0-9]+$')
  echo "$issue_number"
}

# 格式化狀態報告
# 用法: format_status_report "system_metrics" "alert_summary" "analysis"
# 輸出: Markdown 格式的狀態報告
format_status_report() {
  local system_metrics="${1:-{}}"
  local alert_summary="${2:-{}}"
  local analysis="${3:-{}}"

  local hostname
  hostname=$(hostname)
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
  local uptime_info
  uptime_info=$(uptime -p 2>/dev/null || uptime | awk -F'up' '{print $2}' | awk -F',' '{print $1}')

  # 解析指標
  local cpu_usage mem_usage load_1m
  cpu_usage=$(echo "$system_metrics" | jq -r '.cpu.usage_percent // "N/A"')
  mem_usage=$(echo "$system_metrics" | jq -r '.memory.usage_percent // "N/A"')
  load_1m=$(echo "$system_metrics" | jq -r '.load.load_1m // "N/A"')

  # 判斷整體狀態
  local issue_count max_severity status_emoji status_text
  issue_count=$(echo "$alert_summary" | jq -r '.issue_count // 0')
  max_severity=$(echo "$alert_summary" | jq -r '.max_severity // "normal"')

  case "$max_severity" in
    critical|high)
      status_emoji="🔴"
      status_text="異常"
      ;;
    warning|medium)
      status_emoji="⚠️"
      status_text="警告"
      ;;
    *)
      status_emoji="✅"
      status_text="正常"
      ;;
  esac

  # 磁碟使用
  local disk_info
  disk_info=$(echo "$system_metrics" | jq -r '.disks[]? | "  - `\(.mount)`: \(.usage_percent)%"' 2>/dev/null | head -5)
  [[ -z "$disk_info" ]] && disk_info="  - N/A"

  # Docker 狀態（如果有）
  local docker_info=""
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    local running_containers
    running_containers=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
    local unhealthy_containers
    unhealthy_containers=$(docker ps --filter "health=unhealthy" -q 2>/dev/null | wc -l | tr -d ' ')
    docker_info="| Docker | ${running_containers} 運行中 | ${unhealthy_containers} 不健康 |"
  fi

  # 問題列表
  local issues_list=""
  if (( issue_count > 0 )); then
    issues_list=$(echo "$alert_summary" | jq -r '.issues[]? | "- **\(.type)**: \(.metric // .container // .alert_type // "unknown") (\(.severity))"' 2>/dev/null)
  fi

  # 建議動作
  local recommendations=""
  local rec_count
  rec_count=$(echo "$analysis" | jq '.recommendations | length' 2>/dev/null || echo "0")
  if (( rec_count > 0 )); then
    recommendations=$(echo "$analysis" | jq -r '.recommendations[]? | "- \(.action): \(.description)"' 2>/dev/null)
  fi

  # 組合報告
  cat <<EOF
## ${status_emoji} ${hostname} - ${status_text}

**回報時間**: ${timestamp}
**運行時間**: ${uptime_info}

### 📈 系統指標

| 指標 | 數值 | 狀態 |
|------|------|------|
| CPU | ${cpu_usage}% | $(get_status_indicator "$cpu_usage" 80 90) |
| 記憶體 | ${mem_usage}% | $(get_status_indicator "$mem_usage" 85 95) |
| 負載 | ${load_1m} | - |
${docker_info}

### 💾 磁碟使用
${disk_info}

### 🔍 檢查結果

- **問題數量**: ${issue_count}
- **最高嚴重度**: ${max_severity}
$(if [[ -n "$issues_list" ]]; then echo -e "\n**問題列表**:\n${issues_list}"; fi)
$(if [[ -n "$recommendations" ]]; then echo -e "\n**建議動作**:\n${recommendations}"; fi)

---
<sub>🤖 自動回報 by Donna-Ops v1.0.0</sub>
EOF
}

# 取得狀態指示器
# 用法: get_status_indicator "value" "warn_threshold" "critical_threshold"
get_status_indicator() {
  local value="$1"
  local warn="${2:-80}"
  local critical="${3:-90}"

  # 處理非數字
  if [[ ! "$value" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    echo "❓"
    return
  fi

  local int_value
  int_value=$(printf "%.0f" "$value")

  if (( int_value >= critical )); then
    echo "🔴"
  elif (( int_value >= warn )); then
    echo "⚠️"
  else
    echo "✅"
  fi
}

# 回報狀態到 GitHub
# 用法: report_status_to_github "system_metrics" "alert_summary" "analysis"
# 返回: 0=成功, 1=失敗
report_status_to_github() {
  local system_metrics="${1:-{}}"
  local alert_summary="${2:-{}}"
  local analysis="${3:-{}}"

  if [[ -z "$GITHUB_REPO" ]]; then
    echo '{"success": false, "error": "GITHUB_REPO not configured"}'
    return 1
  fi

  # 取得或建立狀態 Issue
  if [[ -z "$STATUS_ISSUE_NUMBER" ]]; then
    STATUS_ISSUE_NUMBER=$(get_or_create_status_issue)
    if [[ -z "$STATUS_ISSUE_NUMBER" ]]; then
      echo '{"success": false, "error": "Failed to get or create status issue"}'
      return 1
    fi
  fi

  # 格式化報告
  local report
  report=$(format_status_report "$system_metrics" "$alert_summary" "$analysis")

  # Dry-run 模式
  if [[ "${GITHUB_DRY_RUN:-false}" == "true" ]]; then
    cat <<EOF
{
  "dry_run": true,
  "action": "report_status",
  "issue_number": $STATUS_ISSUE_NUMBER,
  "hostname": "$(hostname)",
  "report_preview": $(echo "$report" | head -c 300 | jq -Rs '.')
}
EOF
    return 0
  fi

  # 發送留言
  local result
  result=$(_gh_status_retry issue comment "$STATUS_ISSUE_NUMBER" \
    --repo "$GITHUB_REPO" \
    --body "$report" \
    2>&1)

  if [[ $? -ne 0 ]]; then
    echo "{\"success\": false, \"error\": $(echo "$result" | jq -Rs '.')}"
    return 1
  fi

  cat <<EOF
{
  "success": true,
  "issue_number": $STATUS_ISSUE_NUMBER,
  "hostname": "$(hostname)",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF
}

# 檢查是否應該回報狀態（基於時間間隔）
# 用法: should_report_status
# 返回: 0=應該回報, 1=不需要
should_report_status() {
  local state_dir="${SCRIPT_DIR:-/opt/donna-ops}/state"
  local last_report_file="${state_dir}/last_status_report"

  # 確保目錄存在
  mkdir -p "$state_dir" 2>/dev/null || true

  # 檢查上次回報時間
  if [[ -f "$last_report_file" ]]; then
    local last_report
    last_report=$(cat "$last_report_file")
    local now
    now=$(date +%s)
    local interval_seconds=$((STATUS_REPORT_INTERVAL * 60))

    if (( now - last_report < interval_seconds )); then
      return 1  # 還在冷卻期
    fi
  fi

  return 0  # 應該回報
}

# 記錄回報時間
# 用法: mark_status_reported
mark_status_reported() {
  local state_dir="${SCRIPT_DIR:-/opt/donna-ops}/state"
  local last_report_file="${state_dir}/last_status_report"

  mkdir -p "$state_dir" 2>/dev/null || true
  date +%s > "$last_report_file"
}

# 強制回報狀態（忽略時間間隔）
# 用法: force_report_status "system_metrics" "alert_summary" "analysis"
force_report_status() {
  local system_metrics="${1:-{}}"
  local alert_summary="${2:-{}}"
  local analysis="${3:-{}}"

  local result
  result=$(report_status_to_github "$system_metrics" "$alert_summary" "$analysis")
  local exit_code=$?

  if [[ $exit_code -eq 0 ]]; then
    mark_status_reported
  fi

  echo "$result"
  return $exit_code
}

# 條件回報狀態（檢查時間間隔）
# 用法: conditional_report_status "system_metrics" "alert_summary" "analysis"
conditional_report_status() {
  local system_metrics="${1:-{}}"
  local alert_summary="${2:-{}}"
  local analysis="${3:-{}}"

  if ! should_report_status; then
    echo '{"skipped": true, "reason": "Within reporting interval"}'
    return 0
  fi

  force_report_status "$system_metrics" "$alert_summary" "$analysis"
}

# 回報錯誤/警報（立即回報，不受時間間隔限制）
# 用法: report_alert_to_github "alert_summary" "analysis"
report_alert_to_github() {
  local alert_summary="${1:-{}}"
  local analysis="${2:-{}}"

  if [[ -z "$GITHUB_REPO" ]]; then
    return 1
  fi

  local issue_count
  issue_count=$(echo "$alert_summary" | jq -r '.issue_count // 0')

  # 只在有問題時立即回報
  if (( issue_count > 0 )); then
    # 收集簡要系統資訊
    local system_metrics="{}"
    if command -v collect_quick_metrics >/dev/null 2>&1; then
      system_metrics=$(collect_quick_metrics 2>/dev/null || echo "{}")
    fi

    force_report_status "$system_metrics" "$alert_summary" "$analysis"
  fi
}

# 取得狀態 Issue URL
# 用法: get_status_issue_url
get_status_issue_url() {
  if [[ -z "$STATUS_ISSUE_NUMBER" ]]; then
    STATUS_ISSUE_NUMBER=$(get_or_create_status_issue)
  fi

  if [[ -n "$STATUS_ISSUE_NUMBER" && -n "$GITHUB_REPO" ]]; then
    echo "https://github.com/${GITHUB_REPO}/issues/${STATUS_ISSUE_NUMBER}"
  else
    echo ""
  fi
}

# 快速收集系統指標（輕量版本）
collect_quick_metrics() {
  local cpu_usage mem_usage load_1m

  # CPU（簡單計算）
  if [[ -f /proc/stat ]]; then
    local idle_pct
    idle_pct=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $8}' | tr -d '%id,' || echo "0")
    cpu_usage=$(echo "100 - ${idle_pct:-0}" | bc 2>/dev/null || echo "0")
  else
    cpu_usage="0"
  fi

  # 記憶體
  if command -v free >/dev/null 2>&1; then
    mem_usage=$(free | awk '/Mem:/ {printf("%.1f", ($3/$2) * 100)}')
  else
    mem_usage="0"
  fi

  # 負載
  load_1m=$(cat /proc/loadavg 2>/dev/null | awk '{print $1}' || echo "0")

  # 磁碟
  local disks
  disks=$(df -h 2>/dev/null | awk 'NR>1 && $5 ~ /[0-9]+%/ {gsub(/%/,"",$5); print "{\"mount\":\""$6"\",\"usage_percent\":"$5"}"}' | jq -s '.' 2>/dev/null || echo "[]")

  cat <<EOF
{
  "cpu": {"usage_percent": $cpu_usage},
  "memory": {"usage_percent": $mem_usage},
  "load": {"load_1m": $load_1m},
  "disks": $disks
}
EOF
}
