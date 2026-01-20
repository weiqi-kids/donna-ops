#!/usr/bin/env bash
###############################################
# lib/validator.sh
# 配置驗證模組
#
# 功能：
#   - 驗證 config.yaml 配置
#   - 檢查必要的依賴工具
#   - 測試外部服務連線
#
# 函式：
#   validate_all()          執行完整驗證
#   validate_config()       驗證配置檔案
#   validate_dependencies() 驗證依賴工具
#   validate_connections()  驗證外部連線
###############################################

if [[ -n "${VALIDATOR_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
VALIDATOR_SH_LOADED=1

# 驗證結果
declare -g VALIDATOR_ERRORS=0
declare -g VALIDATOR_WARNINGS=0

# 記錄驗證錯誤
_validator_error() {
  local message="$1"
  echo "  [ERROR] $message"
  ((VALIDATOR_ERRORS++))
}

# 記錄驗證警告
_validator_warn() {
  local message="$1"
  echo "  [WARN]  $message"
  ((VALIDATOR_WARNINGS++))
}

# 記錄驗證成功
_validator_ok() {
  local message="$1"
  echo "  [OK]    $message"
}

# 驗證配置檔案
# 用法: validate_config [config_file]
validate_config() {
  local config_file="${1:-${SCRIPT_DIR}/config/config.yaml}"

  echo "【配置檔案驗證】"

  # 檢查檔案是否存在
  if [[ ! -f "$config_file" ]]; then
    _validator_error "配置檔案不存在: $config_file"
    return 1
  fi
  _validator_ok "配置檔案存在"

  # 檢查 YAML 語法（如果有 yq）
  if command -v yq >/dev/null 2>&1; then
    if ! yq eval '.' "$config_file" >/dev/null 2>&1; then
      _validator_error "YAML 語法錯誤"
      return 1
    fi
    _validator_ok "YAML 語法正確"
  fi

  # 驗證必要欄位
  local required_fields=(
    "thresholds.cpu_percent"
    "thresholds.memory_percent"
    "thresholds.disk_percent"
  )

  for field in "${required_fields[@]}"; do
    local value
    value=$(config_get "$field" 2>/dev/null)
    if [[ -z "$value" ]]; then
      _validator_warn "建議設定: $field"
    fi
  done

  # 驗證閾值範圍
  local cpu_threshold mem_threshold disk_threshold
  cpu_threshold=$(config_get_int 'thresholds.cpu_percent' 80)
  mem_threshold=$(config_get_int 'thresholds.memory_percent' 85)
  disk_threshold=$(config_get_int 'thresholds.disk_percent' 90)

  if (( cpu_threshold < 1 || cpu_threshold > 100 )); then
    _validator_error "CPU 閾值超出範圍 (1-100): $cpu_threshold"
  fi
  if (( mem_threshold < 1 || mem_threshold > 100 )); then
    _validator_error "記憶體閾值超出範圍 (1-100): $mem_threshold"
  fi
  if (( disk_threshold < 1 || disk_threshold > 100 )); then
    _validator_error "磁碟閾值超出範圍 (1-100): $disk_threshold"
  fi

  # 驗證間隔設定
  local periodic_interval poll_interval
  periodic_interval=$(config_get_int 'intervals.periodic_check_minutes' 5)
  poll_interval=$(config_get_int 'intervals.alert_poll_seconds' 60)

  if (( periodic_interval != -1 && periodic_interval < 1 )); then
    _validator_error "定期檢查間隔必須 >= 1 或 -1 (停用): $periodic_interval"
  fi
  if (( poll_interval != -1 && poll_interval < 10 )); then
    _validator_warn "警報輪詢間隔建議 >= 10 秒: $poll_interval"
  fi

  # 驗證 GitHub 設定
  local github_repo
  github_repo=$(config_get 'github_repo')
  if [[ -z "$github_repo" && "$github_repo" != "auto" ]]; then
    _validator_warn "未設定 GitHub repo，Issue 功能將停用"
  fi

  echo ""
  return 0
}

# 驗證依賴工具
validate_dependencies() {
  echo "【依賴工具驗證】"

  # 必要工具
  local required_tools=(
    "jq:JSON 處理"
    "yq:YAML 解析"
    "curl:HTTP 請求"
    "git:版本控制"
  )

  for tool_desc in "${required_tools[@]}"; do
    local tool="${tool_desc%%:*}"
    local desc="${tool_desc#*:}"
    if command -v "$tool" >/dev/null 2>&1; then
      local version
      version=$("$tool" --version 2>&1 | head -1 | tr -d '\n')
      _validator_ok "$tool ($desc)"
    else
      _validator_error "缺少必要工具: $tool ($desc)"
    fi
  done

  # 可選工具
  local optional_tools=(
    "gh:GitHub CLI"
    "docker:容器支援"
    "claude:AI 分析"
    "systemctl:服務管理"
  )

  for tool_desc in "${optional_tools[@]}"; do
    local tool="${tool_desc%%:*}"
    local desc="${tool_desc#*:}"
    if command -v "$tool" >/dev/null 2>&1; then
      _validator_ok "$tool ($desc) - 可用"
    else
      _validator_warn "$tool ($desc) - 未安裝，相關功能將停用"
    fi
  done

  echo ""
  return 0
}

# 驗證外部連線
validate_connections() {
  echo "【外部連線驗證】"

  # 測試 GitHub API
  local github_repo
  github_repo=$(config_get_github_repo 2>/dev/null)
  if [[ -n "$github_repo" ]]; then
    if command -v gh >/dev/null 2>&1; then
      if gh auth status >/dev/null 2>&1; then
        _validator_ok "GitHub CLI 已認證"
        # 測試 repo 存取
        if gh repo view "$github_repo" >/dev/null 2>&1; then
          _validator_ok "GitHub repo 可存取: $github_repo"
        else
          _validator_error "無法存取 GitHub repo: $github_repo"
        fi
      else
        _validator_error "GitHub CLI 未認證，請執行 'gh auth login'"
      fi
    fi
  fi

  # 測試 Linode API
  local linode_token
  linode_token=$(config_get 'linode_api_token')
  if [[ -n "$linode_token" ]]; then
    local linode_test
    linode_test=$(curl -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer $linode_token" \
      "https://api.linode.com/v4/account" 2>/dev/null)
    if [[ "$linode_test" == "200" ]]; then
      _validator_ok "Linode API 連線正常"
    else
      _validator_error "Linode API 連線失敗 (HTTP $linode_test)"
    fi
  fi

  # 測試通知服務
  local slack_webhook
  slack_webhook=$(config_get 'notifications.slack_webhook')
  if [[ -n "$slack_webhook" ]]; then
    _validator_ok "Slack Webhook 已設定"
  fi

  local telegram_token
  telegram_token=$(config_get 'notifications.telegram_bot_token')
  if [[ -n "$telegram_token" ]]; then
    local telegram_test
    telegram_test=$(curl -s -o /dev/null -w "%{http_code}" \
      "https://api.telegram.org/bot${telegram_token}/getMe" 2>/dev/null)
    if [[ "$telegram_test" == "200" ]]; then
      _validator_ok "Telegram Bot 連線正常"
    else
      _validator_error "Telegram Bot 連線失敗 (HTTP $telegram_test)"
    fi
  fi

  echo ""
  return 0
}

# 驗證目錄權限
validate_permissions() {
  echo "【目錄權限驗證】"

  local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

  # 檢查日誌目錄
  local log_dir="${script_dir}/logs"
  if [[ -d "$log_dir" ]]; then
    if [[ -w "$log_dir" ]]; then
      _validator_ok "日誌目錄可寫入: $log_dir"
    else
      _validator_error "日誌目錄無法寫入: $log_dir"
    fi
  else
    if mkdir -p "$log_dir" 2>/dev/null; then
      _validator_ok "日誌目錄已建立: $log_dir"
    else
      _validator_error "無法建立日誌目錄: $log_dir"
    fi
  fi

  # 檢查狀態目錄
  local state_dir="${script_dir}/state"
  if [[ -d "$state_dir" ]]; then
    if [[ -w "$state_dir" ]]; then
      _validator_ok "狀態目錄可寫入: $state_dir"
    else
      _validator_error "狀態目錄無法寫入: $state_dir"
    fi
  else
    if mkdir -p "$state_dir" 2>/dev/null; then
      _validator_ok "狀態目錄已建立: $state_dir"
    else
      _validator_error "無法建立狀態目錄: $state_dir"
    fi
  fi

  echo ""
  return 0
}

# 執行完整驗證
# 用法: validate_all [config_file]
# 返回: 0=無錯誤, 1=有錯誤
validate_all() {
  local config_file="${1:-}"

  VALIDATOR_ERRORS=0
  VALIDATOR_WARNINGS=0

  echo "╔════════════════════════════════════════╗"
  echo "║       Donna-Ops 配置驗證               ║"
  echo "╚════════════════════════════════════════╝"
  echo ""

  # 執行各項驗證
  validate_config "$config_file"
  validate_dependencies
  validate_permissions
  validate_connections

  # 顯示摘要
  echo "【驗證摘要】"
  echo "  錯誤: $VALIDATOR_ERRORS"
  echo "  警告: $VALIDATOR_WARNINGS"
  echo ""

  if (( VALIDATOR_ERRORS > 0 )); then
    echo "驗證失敗，請修正上述錯誤後再試。"
    return 1
  elif (( VALIDATOR_WARNINGS > 0 )); then
    echo "驗證通過（有警告），建議檢視上述警告。"
    return 0
  else
    echo "驗證通過，配置正確！"
    return 0
  fi
}

# 快速驗證（只檢查必要項目）
validate_quick() {
  VALIDATOR_ERRORS=0

  # 檢查配置檔案
  local config_file="${SCRIPT_DIR:-/opt/donna-ops}/config/config.yaml"
  if [[ ! -f "$config_file" ]]; then
    return 1
  fi

  # 檢查必要工具
  for tool in jq yq curl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      return 1
    fi
  done

  return 0
}
