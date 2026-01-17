#!/usr/bin/env bash
###############################################
# remediation/validators/safety-check.sh
# 安全性驗證
#   - is_low_risk_action()        檢查是否為低風險動作
#   - check_system_stability()    系統穩定性檢查
#   - validate_command_safety()   指令黑名單檢查
###############################################

if [[ -n "${VALIDATOR_SAFETY_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
VALIDATOR_SAFETY_SH_LOADED=1

# 低風險動作清單
declare -ga LOW_RISK_ACTIONS=(
  "clear-cache"
  "docker-prune"
  "rotate-logs"
)

# 中風險動作清單
declare -ga MEDIUM_RISK_ACTIONS=(
  "restart-service"
  "kill-runaway"
)

# 高風險動作清單（需人工確認）
declare -ga HIGH_RISK_ACTIONS=(
  "restart-docker"
  "reboot"
)

# 危險指令黑名單
declare -ga DANGEROUS_COMMANDS=(
  "rm -rf /"
  "rm -rf /*"
  "mkfs"
  "dd if=/dev/zero"
  ":(){:|:&};:"
  "chmod -R 777 /"
  "chown -R"
  "> /dev/sda"
  "mv /* /dev/null"
  "wget .* | sh"
  "curl .* | sh"
  "shutdown"
  "init 0"
  "halt"
  "poweroff"
)

# 檢查是否為低風險動作
# 用法：is_low_risk_action "action_name"
# 回傳：0 = 低風險，1 = 非低風險
is_low_risk_action() {
  local action="$1"

  for low_risk in "${LOW_RISK_ACTIONS[@]}"; do
    if [[ "$action" == "$low_risk" ]]; then
      return 0
    fi
  done

  return 1
}

# 取得動作風險等級
# 用法：get_action_risk_level "action_name"
# 回傳：low, medium, high, critical
get_action_risk_level() {
  local action="$1"

  for item in "${LOW_RISK_ACTIONS[@]}"; do
    [[ "$action" == "$item" ]] && echo "low" && return
  done

  for item in "${MEDIUM_RISK_ACTIONS[@]}"; do
    [[ "$action" == "$item" ]] && echo "medium" && return
  done

  for item in "${HIGH_RISK_ACTIONS[@]}"; do
    [[ "$action" == "$item" ]] && echo "high" && return
  done

  echo "critical"
}

# 檢查系統穩定性
# 用法：check_system_stability
# 回傳 JSON：{"stable": true/false, "issues": [...]}
check_system_stability() {
  local issues="[]"
  local stable="true"

  # 1. 檢查系統負載
  local load1 cpu_count
  if [[ "$(uname)" == "Darwin" ]]; then
    load1=$(sysctl -n vm.loadavg | awk '{print $1}')
    cpu_count=$(sysctl -n hw.ncpu)
  else
    load1=$(cat /proc/loadavg | awk '{print $1}')
    cpu_count=$(nproc)
  fi

  local load_ratio
  load_ratio=$(echo "scale=2; $load1 / $cpu_count" | bc -l 2>/dev/null || echo "0")

  # 負載超過 CPU 數量的 3 倍視為不穩定
  if (( $(echo "$load_ratio > 3" | bc -l 2>/dev/null || echo 0) )); then
    stable="false"
    issues=$(echo "$issues" | jq --arg msg "系統負載過高: $load1 (${cpu_count} CPUs)" '. + [$msg]')
  fi

  # 2. 檢查記憶體
  local mem_free_percent
  if [[ "$(uname)" == "Darwin" ]]; then
    local pages_free page_size total_mem
    page_size=$(pagesize)
    pages_free=$(vm_stat | grep "Pages free" | awk '{print $3}' | tr -d '.')
    total_mem=$(sysctl -n hw.memsize)
    mem_free_percent=$(echo "scale=0; $pages_free * $page_size * 100 / $total_mem" | bc 2>/dev/null || echo 50)
  else
    local total available
    total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    available=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    mem_free_percent=$(echo "scale=0; $available * 100 / $total" | bc 2>/dev/null || echo 50)
  fi

  # 可用記憶體低於 5% 視為不穩定
  if (( mem_free_percent < 5 )); then
    stable="false"
    issues=$(echo "$issues" | jq --arg msg "可用記憶體過低: ${mem_free_percent}%" '. + [$msg]')
  fi

  # 3. 檢查磁碟空間（根目錄）
  local root_usage
  root_usage=$(df -k / | tail -1 | awk '{print $5}' | tr -d '%')
  if (( root_usage > 98 )); then
    stable="false"
    issues=$(echo "$issues" | jq --arg msg "根目錄磁碟空間不足: ${root_usage}%" '. + [$msg]')
  fi

  # 4. 檢查是否有 OOM killer 最近活動
  if command -v journalctl >/dev/null 2>&1; then
    local oom_count
    oom_count=$(journalctl --since "5 minutes ago" 2>/dev/null | grep -c "oom-killer\|Out of memory" || echo 0)
    if (( oom_count > 0 )); then
      stable="false"
      issues=$(echo "$issues" | jq --arg msg "偵測到 OOM killer 活動 (最近5分鐘: $oom_count 次)" '. + [$msg]')
    fi
  fi

  # 5. 檢查重要服務
  if command -v systemctl >/dev/null 2>&1; then
    local failed_services
    failed_services=$(systemctl --failed --no-legend 2>/dev/null | wc -l | tr -d ' ')
    if (( failed_services > 0 )); then
      issues=$(echo "$issues" | jq --arg msg "有 $failed_services 個 systemd 服務失敗" '. + [$msg]')
    fi
  fi

  cat <<EOF
{
  "stable": $stable,
  "checks": {
    "load_ratio": $load_ratio,
    "memory_free_percent": $mem_free_percent,
    "root_disk_usage": $root_usage
  },
  "issues": $issues
}
EOF
}

# 驗證指令安全性
# 用法：validate_command_safety "command"
# 回傳：0 = 安全，1 = 危險
validate_command_safety() {
  local command="$1"

  # 檢查黑名單
  for dangerous in "${DANGEROUS_COMMANDS[@]}"; do
    if [[ "$command" =~ $dangerous ]]; then
      echo "ERROR: 偵測到危險指令模式: $dangerous" >&2
      return 1
    fi
  done

  # 檢查特定危險模式

  # rm -rf 跟隨重要路徑
  if [[ "$command" =~ rm[[:space:]]+-rf?[[:space:]]+(/|/etc|/var|/usr|/home|/root|/boot) ]]; then
    echo "ERROR: 偵測到危險的 rm 指令" >&2
    return 1
  fi

  # chmod/chown 對系統目錄的遞迴操作
  if [[ "$command" =~ (chmod|chown)[[:space:]]+-R[[:space:]]+.*[[:space:]]+/ ]]; then
    echo "ERROR: 偵測到對根目錄的遞迴權限變更" >&2
    return 1
  fi

  # 從網路下載並直接執行
  if [[ "$command" =~ (curl|wget).*\|.*(sh|bash) ]]; then
    echo "ERROR: 偵測到從網路下載並執行的模式" >&2
    return 1
  fi

  # 重定向到塊裝置
  if [[ "$command" =~ \>[[:space:]]*/dev/(sd|hd|nvme|vd) ]]; then
    echo "ERROR: 偵測到對塊裝置的重定向" >&2
    return 1
  fi

  return 0
}

# 檢查動作是否可以自動執行
# 用法：can_auto_execute "action_name" "target"
# 回傳：0 = 可以，1 = 不可以
can_auto_execute() {
  local action="$1"
  local target="${2:-}"

  # 1. 必須是低風險動作
  if ! is_low_risk_action "$action"; then
    return 1
  fi

  # 2. 系統必須穩定
  local stability
  stability=$(check_system_stability)
  local is_stable
  is_stable=$(echo "$stability" | jq -r '.stable')
  if [[ "$is_stable" != "true" ]]; then
    return 1
  fi

  return 0
}

# 預執行安全檢查
# 用法：pre_execution_check "action_name" "target"
# 回傳 JSON
pre_execution_check() {
  local action="$1"
  local target="${2:-}"

  local risk_level can_auto stability
  risk_level=$(get_action_risk_level "$action")
  stability=$(check_system_stability)
  local is_stable
  is_stable=$(echo "$stability" | jq -r '.stable')

  local approved="false"
  local reason=""

  if [[ "$risk_level" == "low" && "$is_stable" == "true" ]]; then
    approved="true"
    reason="低風險動作且系統穩定"
  elif [[ "$risk_level" == "low" && "$is_stable" != "true" ]]; then
    approved="false"
    reason="系統目前不穩定，不建議執行任何動作"
  elif [[ "$risk_level" == "medium" ]]; then
    approved="false"
    reason="中風險動作需要 AI 分析確認"
  else
    approved="false"
    reason="高風險動作需要人工確認"
  fi

  cat <<EOF
{
  "action": "$action",
  "target": "$target",
  "risk_level": "$risk_level",
  "system_stable": $is_stable,
  "approved": $approved,
  "reason": "$reason",
  "stability_details": $stability
}
EOF
}

# 動作執行前確認（互動式）
confirm_action() {
  local action="$1"
  local target="${2:-}"
  local risk_level
  risk_level=$(get_action_risk_level "$action")

  echo "=========================="
  echo "動作確認"
  echo "=========================="
  echo "動作：$action"
  echo "目標：${target:-N/A}"
  echo "風險等級：$risk_level"
  echo ""

  if [[ "$risk_level" == "high" || "$risk_level" == "critical" ]]; then
    echo "警告：這是一個高風險操作！"
  fi

  read -p "確定要執行嗎？(yes/no): " confirm
  [[ "${confirm,,}" == "yes" ]]
}

# 添加自訂低風險動作
add_low_risk_action() {
  local action="$1"
  LOW_RISK_ACTIONS+=("$action")
}

# 添加危險指令模式
add_dangerous_command() {
  local pattern="$1"
  DANGEROUS_COMMANDS+=("$pattern")
}
