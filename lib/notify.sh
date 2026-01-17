#!/usr/bin/env bash
###############################################
# notify.sh
# 通知功能
#   - notify_slack()     發送 Slack 通知
#   - notify_telegram()  發送 Telegram 通知
#   - notify_all()       發送到所有已設定的管道
###############################################

if [[ -n "${NOTIFY_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
NOTIFY_SH_LOADED=1

# 全域變數（由 config 設定）
declare -g NOTIFY_SLACK_WEBHOOK=""
declare -g NOTIFY_TELEGRAM_BOT_TOKEN=""
declare -g NOTIFY_TELEGRAM_CHAT_ID=""
declare -g NOTIFY_DRY_RUN="false"

# 初始化通知設定
notify_init() {
  NOTIFY_SLACK_WEBHOOK="${1:-}"
  NOTIFY_TELEGRAM_BOT_TOKEN="${2:-}"
  NOTIFY_TELEGRAM_CHAT_ID="${3:-}"
}

# 發送 Slack 通知
# 用法：notify_slack "訊息" ["severity"]
# severity: info, warning, error
notify_slack() {
  local message="$1"
  local severity="${2:-info}"

  if [[ -z "$NOTIFY_SLACK_WEBHOOK" ]]; then
    return 0  # 未設定則跳過
  fi

  if [[ "$NOTIFY_DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Slack: $message"
    return 0
  fi

  # 根據 severity 設定顏色
  local color
  case "$severity" in
    error)   color="#dc3545" ;;  # 紅
    warning) color="#ffc107" ;;  # 黃
    success) color="#28a745" ;;  # 綠
    *)       color="#17a2b8" ;;  # 藍
  esac

  local hostname
  hostname=$(hostname 2>/dev/null || echo "unknown")
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  # 建立 Slack payload
  local payload
  payload=$(cat <<EOF
{
  "attachments": [
    {
      "color": "${color}",
      "title": "Donna-Ops Alert",
      "text": "${message}",
      "fields": [
        {"title": "Host", "value": "${hostname}", "short": true},
        {"title": "Severity", "value": "${severity}", "short": true}
      ],
      "footer": "donna-ops",
      "ts": $(date +%s)
    }
  ]
}
EOF
)

  # 發送請求
  local response
  response=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$NOTIFY_SLACK_WEBHOOK" 2>&1)

  if [[ "$response" != "ok" ]]; then
    echo "WARN: Slack 通知可能失敗：$response" >&2
    return 1
  fi

  return 0
}

# 發送 Telegram 通知
# 用法：notify_telegram "訊息" ["severity"]
notify_telegram() {
  local message="$1"
  local severity="${2:-info}"

  if [[ -z "$NOTIFY_TELEGRAM_BOT_TOKEN" || -z "$NOTIFY_TELEGRAM_CHAT_ID" ]]; then
    return 0  # 未設定則跳過
  fi

  if [[ "$NOTIFY_DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Telegram: $message"
    return 0
  fi

  # 加入 emoji 前綴
  local emoji
  case "$severity" in
    error)   emoji="🚨" ;;
    warning) emoji="⚠️" ;;
    success) emoji="✅" ;;
    *)       emoji="ℹ️" ;;
  esac

  local hostname
  hostname=$(hostname 2>/dev/null || echo "unknown")
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  # 組合訊息（使用 MarkdownV2 格式）
  local full_message="${emoji} *Donna\\-Ops Alert*

*Host:* \`${hostname}\`
*Severity:* ${severity}
*Time:* ${timestamp}

${message}"

  # URL 編碼訊息
  local encoded_message
  encoded_message=$(printf '%s' "$full_message" | jq -sRr @uri)

  # 發送請求
  local api_url="https://api.telegram.org/bot${NOTIFY_TELEGRAM_BOT_TOKEN}/sendMessage"
  local response
  response=$(curl -s -X POST "$api_url" \
    -d "chat_id=${NOTIFY_TELEGRAM_CHAT_ID}" \
    -d "text=${full_message}" \
    -d "parse_mode=Markdown" 2>&1)

  local ok
  ok=$(echo "$response" | jq -r '.ok' 2>/dev/null)

  if [[ "$ok" != "true" ]]; then
    echo "WARN: Telegram 通知可能失敗：$response" >&2
    return 1
  fi

  return 0
}

# 發送到所有已設定的管道
# 用法：notify_all "訊息" ["severity"]
notify_all() {
  local message="$1"
  local severity="${2:-info}"
  local errors=0

  if [[ -n "$NOTIFY_SLACK_WEBHOOK" ]]; then
    notify_slack "$message" "$severity" || (( errors++ ))
  fi

  if [[ -n "$NOTIFY_TELEGRAM_BOT_TOKEN" && -n "$NOTIFY_TELEGRAM_CHAT_ID" ]]; then
    notify_telegram "$message" "$severity" || (( errors++ ))
  fi

  return $errors
}

# 發送警報通知（帶有更多上下文）
# 用法：notify_alert "type" "title" "details" "severity"
notify_alert() {
  local alert_type="$1"
  local title="$2"
  local details="${3:-}"
  local severity="${4:-warning}"

  local message="[${alert_type}] ${title}"
  if [[ -n "$details" ]]; then
    message="${message}

${details}"
  fi

  notify_all "$message" "$severity"
}

# 發送修復通知
# 用法：notify_remediation "action" "result" "details"
notify_remediation() {
  local action="$1"
  local result="$2"
  local details="${3:-}"

  local severity="info"
  if [[ "$result" == "failed" ]]; then
    severity="error"
  elif [[ "$result" == "success" ]]; then
    severity="success"
  fi

  local message="Remediation: ${action}
Result: ${result}"

  if [[ -n "$details" ]]; then
    message="${message}
Details: ${details}"
  fi

  notify_all "$message" "$severity"
}

# 設定 dry-run 模式
notify_set_dry_run() {
  local enabled="$1"
  case "${enabled,,}" in
    true|yes|1|on)  NOTIFY_DRY_RUN="true" ;;
    false|no|0|off) NOTIFY_DRY_RUN="false" ;;
  esac
}

# 檢查是否有設定任何通知管道
notify_is_configured() {
  [[ -n "$NOTIFY_SLACK_WEBHOOK" ]] || \
  [[ -n "$NOTIFY_TELEGRAM_BOT_TOKEN" && -n "$NOTIFY_TELEGRAM_CHAT_ID" ]]
}
