#!/usr/bin/env bash
###############################################
# collectors/logs.sh
# 系統日誌收集器
#   - collect_journald()      收集 systemd 日誌
#   - collect_docker_logs()   收集 Docker 容器日誌
#   - collect_syslog()        收集 syslog
#   - collect_error_summary() 收集錯誤摘要
###############################################

if [[ -n "${COLLECTOR_LOGS_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
COLLECTOR_LOGS_SH_LOADED=1

# 收集 systemd journald 日誌
# 用法：collect_journald [since] [priority] [unit]
# since: 時間範圍，如 "1 hour ago", "30 minutes ago"
# priority: 最高優先級 (0=emerg, 3=err, 4=warning)
# unit: 特定服務單元
collect_journald() {
  local since="${1:-1 hour ago}"
  local priority="${2:-4}"  # warning 及以上
  local unit="${3:-}"

  if ! command -v journalctl >/dev/null 2>&1; then
    echo '{"available": false, "entries": []}'
    return 1
  fi

  local cmd="journalctl --no-pager -o json --since \"$since\" -p $priority"
  if [[ -n "$unit" ]]; then
    cmd="$cmd -u $unit"
  fi

  local entries="[]"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # 提取關鍵欄位
    local timestamp unit message priority_num
    timestamp=$(echo "$line" | jq -r '.__REALTIME_TIMESTAMP // empty' 2>/dev/null)
    unit=$(echo "$line" | jq -r '._SYSTEMD_UNIT // .SYSLOG_IDENTIFIER // "unknown"' 2>/dev/null)
    message=$(echo "$line" | jq -r '.MESSAGE // ""' 2>/dev/null)
    priority_num=$(echo "$line" | jq -r '.PRIORITY // "6"' 2>/dev/null)

    # 轉換時間戳（微秒 → ISO 格式）
    local iso_time=""
    if [[ -n "$timestamp" ]]; then
      local seconds=$((timestamp / 1000000))
      iso_time=$(date -d "@$seconds" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
    fi

    # 優先級名稱
    local priority_name
    case "$priority_num" in
      0) priority_name="emerg" ;;
      1) priority_name="alert" ;;
      2) priority_name="crit" ;;
      3) priority_name="err" ;;
      4) priority_name="warning" ;;
      5) priority_name="notice" ;;
      6) priority_name="info" ;;
      7) priority_name="debug" ;;
      *) priority_name="unknown" ;;
    esac

    entries=$(echo "$entries" | jq \
      --arg ts "$iso_time" --arg unit "$unit" \
      --arg msg "$message" --arg pri "$priority_name" \
      '. + [{"timestamp": $ts, "unit": $unit, "priority": $pri, "message": $msg}]')
  done < <(eval "$cmd" 2>/dev/null | head -n 100)

  local count
  count=$(echo "$entries" | jq 'length')

  cat <<EOF
{
  "available": true,
  "since": "$since",
  "priority_filter": "$priority",
  "count": $count,
  "entries": $entries
}
EOF
}

# 收集 Docker 容器日誌
# 用法：collect_docker_logs [container] [since] [lines]
collect_docker_logs() {
  local container="${1:-}"
  local since="${2:-1h}"
  local lines="${3:-50}"

  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo '{"available": false, "logs": []}'
    return 1
  fi

  local logs="[]"

  if [[ -n "$container" ]]; then
    # 單一容器
    local log_output
    log_output=$(docker logs --since "$since" --tail "$lines" "$container" 2>&1)
    local escaped_logs
    escaped_logs=$(echo "$log_output" | jq -Rs '.')
    logs=$(echo "$logs" | jq --arg name "$container" --argjson content "$escaped_logs" \
      '. + [{"container": $name, "logs": $content}]')
  else
    # 所有執行中的容器
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      local log_output
      log_output=$(docker logs --since "$since" --tail "$lines" "$name" 2>&1)
      local escaped_logs
      escaped_logs=$(echo "$log_output" | jq -Rs '.')
      logs=$(echo "$logs" | jq --arg name "$name" --argjson content "$escaped_logs" \
        '. + [{"container": $name, "logs": $content}]')
    done < <(docker ps --format '{{.Names}}' 2>/dev/null)
  fi

  local count
  count=$(echo "$logs" | jq 'length')

  cat <<EOF
{
  "available": true,
  "since": "$since",
  "lines_per_container": $lines,
  "count": $count,
  "logs": $logs
}
EOF
}

# 收集 syslog（/var/log/syslog 或 /var/log/messages）
# 用法：collect_syslog [lines] [pattern]
collect_syslog() {
  local lines="${1:-100}"
  local pattern="${2:-}"

  local syslog_file=""
  if [[ -f /var/log/syslog ]]; then
    syslog_file="/var/log/syslog"
  elif [[ -f /var/log/messages ]]; then
    syslog_file="/var/log/messages"
  fi

  if [[ -z "$syslog_file" ]]; then
    echo '{"available": false, "entries": []}'
    return 1
  fi

  local entries="[]"
  local cmd="tail -n $lines $syslog_file"
  if [[ -n "$pattern" ]]; then
    cmd="$cmd | grep -i \"$pattern\""
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # 嘗試解析 syslog 格式
    # 格式：Jan 15 10:30:00 hostname service[pid]: message
    local timestamp host service message
    if [[ "$line" =~ ^([A-Za-z]+\ +[0-9]+\ [0-9:]+)\ ([^ ]+)\ ([^:]+):\ (.*)$ ]]; then
      timestamp="${BASH_REMATCH[1]}"
      host="${BASH_REMATCH[2]}"
      service="${BASH_REMATCH[3]}"
      message="${BASH_REMATCH[4]}"
    else
      timestamp=""
      host=""
      service=""
      message="$line"
    fi

    entries=$(echo "$entries" | jq \
      --arg ts "$timestamp" --arg host "$host" \
      --arg svc "$service" --arg msg "$message" \
      '. + [{"timestamp": $ts, "host": $host, "service": $svc, "message": $msg}]')
  done < <(eval "$cmd" 2>/dev/null)

  local count
  count=$(echo "$entries" | jq 'length')

  cat <<EOF
{
  "available": true,
  "file": "$syslog_file",
  "count": $count,
  "entries": $entries
}
EOF
}

# 收集錯誤摘要
# 掃描多個來源的錯誤關鍵字
collect_error_summary() {
  local since="${1:-1 hour ago}"

  local summary='{}'
  local errors="[]"

  # 1. journald 錯誤
  if command -v journalctl >/dev/null 2>&1; then
    local journal_errors
    journal_errors=$(journalctl --no-pager -o cat --since "$since" -p 3 2>/dev/null | wc -l | tr -d ' ')
    summary=$(echo "$summary" | jq --argjson n "$journal_errors" '.journald_errors = $n')

    # 收集前 10 條錯誤
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      errors=$(echo "$errors" | jq --arg src "journald" --arg msg "$line" \
        '. + [{"source": $src, "message": $msg}]')
    done < <(journalctl --no-pager -o cat --since "$since" -p 3 2>/dev/null | head -n 10)
  fi

  # 2. Docker 容器錯誤
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    local docker_errors=0
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      local err_count
      err_count=$(docker logs --since "$since" "$name" 2>&1 | grep -ciE '(error|exception|fatal|panic)' || echo 0)
      docker_errors=$((docker_errors + err_count))

      if (( err_count > 0 )); then
        local sample
        sample=$(docker logs --since "$since" "$name" 2>&1 | grep -iE '(error|exception|fatal|panic)' | head -n 2)
        while IFS= read -r line; do
          [[ -z "$line" ]] && continue
          errors=$(echo "$errors" | jq --arg src "docker:$name" --arg msg "$line" \
            '. + [{"source": $src, "message": $msg}]')
        done <<< "$sample"
      fi
    done < <(docker ps --format '{{.Names}}' 2>/dev/null)
    summary=$(echo "$summary" | jq --argjson n "$docker_errors" '.docker_errors = $n')
  fi

  # 3. 系統關鍵錯誤（OOM killer, kernel panic 等）
  local critical_patterns="oom-killer|Out of memory|kernel panic|segfault|BUG:|Call Trace"
  local critical_count=0
  if [[ -f /var/log/kern.log ]]; then
    critical_count=$(grep -ciE "$critical_patterns" /var/log/kern.log 2>/dev/null || echo 0)
  elif command -v journalctl >/dev/null 2>&1; then
    critical_count=$(journalctl -k --since "$since" 2>/dev/null | grep -ciE "$critical_patterns" || echo 0)
  fi
  summary=$(echo "$summary" | jq --argjson n "$critical_count" '.critical_kernel_errors = $n')

  # 計算總錯誤數
  local total
  total=$(echo "$summary" | jq '[.journald_errors // 0, .docker_errors // 0, .critical_kernel_errors // 0] | add')

  cat <<EOF
{
  "since": "$since",
  "total_errors": $total,
  "summary": $summary,
  "sample_errors": $(echo "$errors" | jq '.[0:20]')
}
EOF
}

# 搜尋日誌中的特定模式
# 用法：search_logs "pattern" [since]
search_logs() {
  local pattern="$1"
  local since="${2:-1 hour ago}"

  local results="[]"

  # journald
  if command -v journalctl >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      results=$(echo "$results" | jq --arg src "journald" --arg msg "$line" \
        '. + [{"source": $src, "message": $msg}]')
    done < <(journalctl --no-pager -o cat --since "$since" 2>/dev/null | grep -i "$pattern" | head -n 20)
  fi

  # Docker
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        results=$(echo "$results" | jq --arg src "docker:$name" --arg msg "$line" \
          '. + [{"source": $src, "message": $msg}]')
      done < <(docker logs --since "1h" "$name" 2>&1 | grep -i "$pattern" | head -n 5)
    done < <(docker ps --format '{{.Names}}' 2>/dev/null)
  fi

  local count
  count=$(echo "$results" | jq 'length')

  cat <<EOF
{
  "pattern": "$pattern",
  "since": "$since",
  "count": $count,
  "results": $results
}
EOF
}
