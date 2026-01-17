#!/usr/bin/env bash
###############################################
# analyzers/threshold-checker.sh
# 閾值檢查分析器
#   - check_thresholds()        比對指標與閾值
#   - generate_alert_summary()  產生警報摘要
###############################################

if [[ -n "${ANALYZER_THRESHOLD_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ANALYZER_THRESHOLD_SH_LOADED=1

# 預設閾值
declare -g THRESHOLD_CPU_PERCENT="${THRESHOLD_CPU_PERCENT:-80}"
declare -g THRESHOLD_MEMORY_PERCENT="${THRESHOLD_MEMORY_PERCENT:-85}"
declare -g THRESHOLD_DISK_PERCENT="${THRESHOLD_DISK_PERCENT:-90}"
declare -g THRESHOLD_LOAD_PER_CPU="${THRESHOLD_LOAD_PER_CPU:-2.0}"

# 初始化閾值（從設定）
threshold_init() {
  THRESHOLD_CPU_PERCENT="${1:-$THRESHOLD_CPU_PERCENT}"
  THRESHOLD_MEMORY_PERCENT="${2:-$THRESHOLD_MEMORY_PERCENT}"
  THRESHOLD_DISK_PERCENT="${3:-$THRESHOLD_DISK_PERCENT}"
  THRESHOLD_LOAD_PER_CPU="${4:-$THRESHOLD_LOAD_PER_CPU}"
}

# 檢查單一指標是否超過閾值
# 用法：check_threshold "cpu" 85.5 80
# 回傳：JSON 物件
check_threshold() {
  local metric_name="$1"
  local current_value="$2"
  local threshold="$3"
  local unit="${4:-%}"

  local exceeded="false"
  local severity="ok"
  local diff

  # 使用 bc 進行浮點數比較
  if (( $(echo "$current_value > $threshold" | bc -l 2>/dev/null || echo 0) )); then
    exceeded="true"
    diff=$(echo "$current_value - $threshold" | bc -l)

    # 根據超出程度判定嚴重度
    local exceed_percent
    exceed_percent=$(echo "scale=0; $diff * 100 / $threshold" | bc -l 2>/dev/null || echo 0)

    if (( exceed_percent > 50 )); then
      severity="critical"
    elif (( exceed_percent > 25 )); then
      severity="warning"
    else
      severity="minor"
    fi
  fi

  cat <<EOF
{
  "metric": "$metric_name",
  "current": $current_value,
  "threshold": $threshold,
  "unit": "$unit",
  "exceeded": $exceeded,
  "severity": "$severity"
}
EOF
}

# 檢查所有系統指標
# 用法：check_thresholds "system_metrics_json"
check_thresholds() {
  local metrics_json="${1:-}"

  if [[ -z "$metrics_json" ]]; then
    echo '{"error": "no metrics provided", "violations": []}'
    return 1
  fi

  local violations="[]"
  local has_violations="false"
  local max_severity="ok"

  # 1. 檢查 CPU
  local cpu_usage
  cpu_usage=$(echo "$metrics_json" | jq -r '.cpu.usage_percent // .cpu_percent // 0')
  local cpu_check
  cpu_check=$(check_threshold "cpu" "$cpu_usage" "$THRESHOLD_CPU_PERCENT" "%")
  if [[ $(echo "$cpu_check" | jq -r '.exceeded') == "true" ]]; then
    violations=$(echo "$violations" | jq --argjson v "$cpu_check" '. + [$v]')
    has_violations="true"
    local sev
    sev=$(echo "$cpu_check" | jq -r '.severity')
    max_severity=$(_update_max_severity "$max_severity" "$sev")
  fi

  # 2. 檢查記憶體
  local mem_usage
  mem_usage=$(echo "$metrics_json" | jq -r '.memory.usage_percent // .memory_percent // 0')
  local mem_check
  mem_check=$(check_threshold "memory" "$mem_usage" "$THRESHOLD_MEMORY_PERCENT" "%")
  if [[ $(echo "$mem_check" | jq -r '.exceeded') == "true" ]]; then
    violations=$(echo "$violations" | jq --argjson v "$mem_check" '. + [$v]')
    has_violations="true"
    local sev
    sev=$(echo "$mem_check" | jq -r '.severity')
    max_severity=$(_update_max_severity "$max_severity" "$sev")
  fi

  # 3. 檢查磁碟（可能有多個掛載點）
  local disks
  disks=$(echo "$metrics_json" | jq -c '.disks // []')
  if [[ "$disks" != "[]" && "$disks" != "null" ]]; then
    while IFS= read -r disk; do
      [[ -z "$disk" || "$disk" == "null" ]] && continue
      local mount disk_usage
      mount=$(echo "$disk" | jq -r '.mount')
      disk_usage=$(echo "$disk" | jq -r '.usage_percent')
      local disk_check
      disk_check=$(check_threshold "disk:$mount" "$disk_usage" "$THRESHOLD_DISK_PERCENT" "%")
      if [[ $(echo "$disk_check" | jq -r '.exceeded') == "true" ]]; then
        violations=$(echo "$violations" | jq --argjson v "$disk_check" '. + [$v]')
        has_violations="true"
        local sev
        sev=$(echo "$disk_check" | jq -r '.severity')
        max_severity=$(_update_max_severity "$max_severity" "$sev")
      fi
    done < <(echo "$disks" | jq -c '.[]' 2>/dev/null)
  fi

  # 4. 檢查系統負載
  local load1 cpu_count load_per_cpu threshold_load
  load1=$(echo "$metrics_json" | jq -r '.load.load_1m // .load_1m // 0')
  cpu_count=$(echo "$metrics_json" | jq -r '.load.cpu_count // 1')
  load_per_cpu=$(echo "scale=2; $load1 / $cpu_count" | bc -l 2>/dev/null || echo 0)
  local load_check
  load_check=$(check_threshold "load_per_cpu" "$load_per_cpu" "$THRESHOLD_LOAD_PER_CPU" "")
  if [[ $(echo "$load_check" | jq -r '.exceeded') == "true" ]]; then
    violations=$(echo "$violations" | jq --argjson v "$load_check" '. + [$v]')
    has_violations="true"
    local sev
    sev=$(echo "$load_check" | jq -r '.severity')
    max_severity=$(_update_max_severity "$max_severity" "$sev")
  fi

  local violation_count
  violation_count=$(echo "$violations" | jq 'length')

  cat <<EOF
{
  "has_violations": $has_violations,
  "violation_count": $violation_count,
  "max_severity": "$max_severity",
  "violations": $violations,
  "thresholds": {
    "cpu_percent": $THRESHOLD_CPU_PERCENT,
    "memory_percent": $THRESHOLD_MEMORY_PERCENT,
    "disk_percent": $THRESHOLD_DISK_PERCENT,
    "load_per_cpu": $THRESHOLD_LOAD_PER_CPU
  }
}
EOF
}

# 內部函式：更新最大嚴重度
_update_max_severity() {
  local current="$1"
  local new="$2"

  local -A severity_order=(
    [ok]=0
    [minor]=1
    [warning]=2
    [critical]=3
  )

  local current_level="${severity_order[$current]:-0}"
  local new_level="${severity_order[$new]:-0}"

  if (( new_level > current_level )); then
    echo "$new"
  else
    echo "$current"
  fi
}

# 產生警報摘要
# 用法：generate_alert_summary "threshold_result_json" "docker_result_json" "linode_alerts_json"
generate_alert_summary() {
  local threshold_result="${1:-}"
  local docker_result="${2:-}"
  local linode_alerts="${3:-}"

  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local hostname
  hostname=$(hostname)

  local summary_lines=()
  local all_issues="[]"
  local max_severity="ok"

  # 1. 處理閾值違規
  if [[ -n "$threshold_result" ]]; then
    local has_violations
    has_violations=$(echo "$threshold_result" | jq -r '.has_violations')
    if [[ "$has_violations" == "true" ]]; then
      while IFS= read -r violation; do
        [[ -z "$violation" || "$violation" == "null" ]] && continue
        local metric current threshold severity
        metric=$(echo "$violation" | jq -r '.metric')
        current=$(echo "$violation" | jq -r '.current')
        threshold=$(echo "$violation" | jq -r '.threshold')
        severity=$(echo "$violation" | jq -r '.severity')

        summary_lines+=("$metric: ${current}% (閾值: ${threshold}%) [$severity]")
        all_issues=$(echo "$all_issues" | jq \
          --arg type "threshold" --arg metric "$metric" \
          --arg current "$current" --arg threshold "$threshold" \
          --arg severity "$severity" \
          '. + [{"type": $type, "metric": $metric, "current": ($current|tonumber), "threshold": ($threshold|tonumber), "severity": $severity}]')
        max_severity=$(_update_max_severity "$max_severity" "$severity")
      done < <(echo "$threshold_result" | jq -c '.violations[]' 2>/dev/null)
    fi
  fi

  # 2. 處理 Docker 問題
  if [[ -n "$docker_result" ]]; then
    local unhealthy
    unhealthy=$(echo "$docker_result" | jq -c '.unhealthy // []')
    while IFS= read -r container; do
      [[ -z "$container" || "$container" == "null" ]] && continue
      local name reason
      name=$(echo "$container" | jq -r '.name')
      reason=$(echo "$container" | jq -r '.reason')

      summary_lines+=("Docker: $name ($reason)")
      all_issues=$(echo "$all_issues" | jq \
        --arg type "docker" --arg name "$name" --arg reason "$reason" \
        '. + [{"type": $type, "container": $name, "reason": $reason, "severity": "warning"}]')
      max_severity=$(_update_max_severity "$max_severity" "warning")
    done < <(echo "$unhealthy" | jq -c '.[]' 2>/dev/null)
  fi

  # 3. 處理 Linode 警報
  if [[ -n "$linode_alerts" ]]; then
    local alerts
    alerts=$(echo "$linode_alerts" | jq -c '.alerts // []')
    while IFS= read -r alert; do
      [[ -z "$alert" || "$alert" == "null" ]] && continue
      local alert_type message severity
      alert_type=$(echo "$alert" | jq -r '.type')
      message=$(echo "$alert" | jq -r '.message')
      severity=$(echo "$alert" | jq -r '.severity')

      # 轉換 Linode 嚴重度
      local mapped_severity
      case "$severity" in
        critical) mapped_severity="critical" ;;
        major)    mapped_severity="warning" ;;
        *)        mapped_severity="minor" ;;
      esac

      summary_lines+=("Linode: $alert_type - $message")
      all_issues=$(echo "$all_issues" | jq \
        --arg type "linode" --arg alert_type "$alert_type" \
        --arg message "$message" --arg severity "$mapped_severity" \
        '. + [{"type": $type, "alert_type": $alert_type, "message": $message, "severity": $severity}]')
      max_severity=$(_update_max_severity "$max_severity" "$mapped_severity")
    done < <(echo "$alerts" | jq -c '.[]' 2>/dev/null)
  fi

  local issue_count
  issue_count=$(echo "$all_issues" | jq 'length')

  # 組合摘要文字
  local summary_text=""
  if (( issue_count > 0 )); then
    summary_text=$(printf '%s\n' "${summary_lines[@]}")
  else
    summary_text="所有指標正常"
  fi

  cat <<EOF
{
  "timestamp": "$timestamp",
  "hostname": "$hostname",
  "issue_count": $issue_count,
  "max_severity": "$max_severity",
  "summary": $(echo "$summary_text" | jq -Rs '.'),
  "issues": $all_issues
}
EOF
}

# 快速檢查：是否有任何問題
has_any_issues() {
  local summary_json="$1"
  local count
  count=$(echo "$summary_json" | jq -r '.issue_count // 0')
  (( count > 0 ))
}

# 判斷是否需要人工介入
requires_human_intervention() {
  local summary_json="$1"
  local severity
  severity=$(echo "$summary_json" | jq -r '.max_severity')

  [[ "$severity" == "critical" || "$severity" == "warning" ]]
}

# 取得建議的修復動作
get_suggested_actions() {
  local summary_json="$1"

  local actions="[]"

  while IFS= read -r issue; do
    [[ -z "$issue" || "$issue" == "null" ]] && continue

    local type metric reason action_name
    type=$(echo "$issue" | jq -r '.type')

    case "$type" in
      threshold)
        metric=$(echo "$issue" | jq -r '.metric')
        case "$metric" in
          cpu)
            actions=$(echo "$actions" | jq '. + [{"action": "kill-runaway", "reason": "CPU 使用率過高"}]')
            ;;
          memory)
            actions=$(echo "$actions" | jq '. + [{"action": "clear-cache", "reason": "記憶體使用率過高"}]')
            ;;
          disk:*)
            actions=$(echo "$actions" | jq '. + [{"action": "docker-prune", "reason": "磁碟使用率過高"}]')
            actions=$(echo "$actions" | jq '. + [{"action": "rotate-logs", "reason": "磁碟使用率過高"}]')
            ;;
          load_per_cpu)
            actions=$(echo "$actions" | jq '. + [{"action": "kill-runaway", "reason": "系統負載過高"}]')
            ;;
        esac
        ;;
      docker)
        reason=$(echo "$issue" | jq -r '.reason')
        case "$reason" in
          not_running)
            local container
            container=$(echo "$issue" | jq -r '.container')
            actions=$(echo "$actions" | jq --arg c "$container" '. + [{"action": "restart-service", "target": $c, "reason": "容器未執行"}]')
            ;;
          health_check_failed)
            local container
            container=$(echo "$issue" | jq -r '.container')
            actions=$(echo "$actions" | jq --arg c "$container" '. + [{"action": "restart-service", "target": $c, "reason": "健康檢查失敗"}]')
            ;;
          high_resource_usage)
            actions=$(echo "$actions" | jq '. + [{"action": "docker-prune", "reason": "容器資源使用過高"}]')
            ;;
        esac
        ;;
    esac
  done < <(echo "$summary_json" | jq -c '.issues[]' 2>/dev/null)

  # 去重
  echo "$actions" | jq 'unique_by(.action + (.target // ""))'
}
