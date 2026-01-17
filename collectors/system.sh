#!/usr/bin/env bash
###############################################
# collectors/system.sh
# 系統指標收集器
#   - collect_cpu()           收集 CPU 使用率
#   - collect_memory()        收集記憶體使用率
#   - collect_disk()          收集磁碟使用率
#   - collect_load()          收集系統負載
#   - collect_top_processes() 收集佔用最多資源的程序
#   - collect_all_system()    收集所有系統指標
###############################################

if [[ -n "${COLLECTOR_SYSTEM_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
COLLECTOR_SYSTEM_SH_LOADED=1

# 收集 CPU 使用率
# 回傳 JSON：{"usage_percent": 25.5, "idle_percent": 74.5}
collect_cpu() {
  local cpu_info

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS：使用 top
    local cpu_usage
    cpu_usage=$(top -l 1 -n 0 | grep "CPU usage" | awk '{print $3}' | tr -d '%')
    local idle
    idle=$(echo "100 - $cpu_usage" | bc 2>/dev/null || echo "0")
    cpu_info=$(printf '{"usage_percent": %.1f, "idle_percent": %.1f}' "$cpu_usage" "$idle")
  else
    # Linux：使用 /proc/stat
    local cpu_line1 cpu_line2
    cpu_line1=$(grep '^cpu ' /proc/stat)
    sleep 0.5
    cpu_line2=$(grep '^cpu ' /proc/stat)

    # 計算差值
    local user1 nice1 system1 idle1 iowait1 irq1 softirq1
    local user2 nice2 system2 idle2 iowait2 irq2 softirq2
    read -r _ user1 nice1 system1 idle1 iowait1 irq1 softirq1 _ <<< "$cpu_line1"
    read -r _ user2 nice2 system2 idle2 iowait2 irq2 softirq2 _ <<< "$cpu_line2"

    local total1 total2 idle_total1 idle_total2
    total1=$((user1 + nice1 + system1 + idle1 + iowait1 + irq1 + softirq1))
    total2=$((user2 + nice2 + system2 + idle2 + iowait2 + irq2 + softirq2))
    idle_total1=$((idle1 + iowait1))
    idle_total2=$((idle2 + iowait2))

    local total_diff idle_diff usage_percent idle_percent
    total_diff=$((total2 - total1))
    idle_diff=$((idle_total2 - idle_total1))

    if (( total_diff > 0 )); then
      usage_percent=$(echo "scale=1; (1 - $idle_diff / $total_diff) * 100" | bc)
      idle_percent=$(echo "scale=1; $idle_diff / $total_diff * 100" | bc)
    else
      usage_percent="0.0"
      idle_percent="100.0"
    fi

    cpu_info=$(printf '{"usage_percent": %s, "idle_percent": %s}' "$usage_percent" "$idle_percent")
  fi

  echo "$cpu_info"
}

# 收集記憶體使用率
# 回傳 JSON：{"total_mb": 8192, "used_mb": 4096, "free_mb": 4096, "usage_percent": 50.0}
collect_memory() {
  local mem_info

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS
    local page_size pages_free pages_active pages_inactive pages_wired
    page_size=$(pagesize)
    local vm_stat_output
    vm_stat_output=$(vm_stat)
    pages_free=$(echo "$vm_stat_output" | grep "Pages free" | awk '{print $3}' | tr -d '.')
    pages_active=$(echo "$vm_stat_output" | grep "Pages active" | awk '{print $3}' | tr -d '.')
    pages_inactive=$(echo "$vm_stat_output" | grep "Pages inactive" | awk '{print $3}' | tr -d '.')
    pages_wired=$(echo "$vm_stat_output" | grep "Pages wired down" | awk '{print $4}' | tr -d '.')

    local total_mb used_mb free_mb
    total_mb=$(sysctl -n hw.memsize | awk '{print int($1/1024/1024)}')
    used_mb=$(echo "($pages_active + $pages_wired) * $page_size / 1024 / 1024" | bc)
    free_mb=$((total_mb - used_mb))
    local usage_percent
    usage_percent=$(echo "scale=1; $used_mb * 100 / $total_mb" | bc)

    mem_info=$(printf '{"total_mb": %d, "used_mb": %d, "free_mb": %d, "usage_percent": %s}' \
      "$total_mb" "$used_mb" "$free_mb" "$usage_percent")
  else
    # Linux：使用 /proc/meminfo
    local total_kb available_kb used_kb
    total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    available_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    used_kb=$((total_kb - available_kb))

    local total_mb used_mb free_mb usage_percent
    total_mb=$((total_kb / 1024))
    used_mb=$((used_kb / 1024))
    free_mb=$((available_kb / 1024))
    usage_percent=$(echo "scale=1; $used_kb * 100 / $total_kb" | bc)

    mem_info=$(printf '{"total_mb": %d, "used_mb": %d, "free_mb": %d, "usage_percent": %s}' \
      "$total_mb" "$used_mb" "$free_mb" "$usage_percent")
  fi

  echo "$mem_info"
}

# 收集磁碟使用率
# 回傳 JSON 陣列：[{"mount": "/", "total_gb": 100, "used_gb": 50, "usage_percent": 50}]
collect_disk() {
  local disks="[]"

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS
    while IFS= read -r line; do
      local fs size used avail percent mount
      read -r fs size used avail percent mount <<< "$line"
      # 移除 % 符號
      percent="${percent%\%}"
      # 轉換為 GB（df -g 輸出已是 GB）
      disks=$(echo "$disks" | jq --arg m "$mount" --argjson t "$size" \
        --argjson u "$used" --argjson p "$percent" \
        '. + [{"mount": $m, "total_gb": $t, "used_gb": $u, "usage_percent": $p}]')
    done < <(df -g 2>/dev/null | grep -E '^/dev/' | awk '{print $1, $2, $3, $4, $5, $9}')
  else
    # Linux
    while IFS= read -r line; do
      local fs size used avail percent mount
      read -r fs size used avail percent mount <<< "$line"
      percent="${percent%\%}"
      # 轉換 KB 為 GB
      local total_gb=$((size / 1024 / 1024))
      local used_gb=$((used / 1024 / 1024))
      disks=$(echo "$disks" | jq --arg m "$mount" --argjson t "$total_gb" \
        --argjson u "$used_gb" --argjson p "$percent" \
        '. + [{"mount": $m, "total_gb": $t, "used_gb": $u, "usage_percent": $p}]')
    done < <(df -k 2>/dev/null | grep -E '^/dev/' | awk '{print $1, $2, $3, $4, $5, $6}')
  fi

  echo "$disks"
}

# 收集系統負載
# 回傳 JSON：{"load_1m": 1.5, "load_5m": 1.2, "load_15m": 0.8, "cpu_count": 4}
collect_load() {
  local load1 load5 load15 cpu_count

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS
    read -r load1 load5 load15 <<< "$(sysctl -n vm.loadavg | awk '{print $1, $2, $3}')"
    cpu_count=$(sysctl -n hw.ncpu)
  else
    # Linux
    read -r load1 load5 load15 _ <<< "$(cat /proc/loadavg)"
    cpu_count=$(nproc)
  fi

  printf '{"load_1m": %s, "load_5m": %s, "load_15m": %s, "cpu_count": %d}' \
    "$load1" "$load5" "$load15" "$cpu_count"
}

# 收集佔用最多資源的程序
# 用法：collect_top_processes [count] [sort_by]
# sort_by: cpu 或 mem
# 回傳 JSON 陣列
collect_top_processes() {
  local count="${1:-5}"
  local sort_by="${2:-cpu}"

  local processes="[]"

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS
    local sort_flag="-o cpu"
    if [[ "$sort_by" == "mem" ]]; then
      sort_flag="-o mem"
    fi

    while IFS= read -r line; do
      local pid cpu mem command
      read -r pid cpu mem command <<< "$line"
      processes=$(echo "$processes" | jq \
        --argjson pid "$pid" --argjson cpu "$cpu" --argjson mem "$mem" --arg cmd "$command" \
        '. + [{"pid": $pid, "cpu_percent": $cpu, "mem_percent": $mem, "command": $cmd}]')
    done < <(ps -Ao pid,%cpu,%mem,comm $sort_flag | tail -n +2 | head -n "$count")
  else
    # Linux
    local sort_key="-%cpu"
    if [[ "$sort_by" == "mem" ]]; then
      sort_key="-%mem"
    fi

    while IFS= read -r line; do
      local pid cpu mem command
      read -r pid cpu mem command <<< "$line"
      processes=$(echo "$processes" | jq \
        --argjson pid "$pid" --arg cpu "$cpu" --arg mem "$mem" --arg cmd "$command" \
        '. + [{"pid": ($pid|tonumber), "cpu_percent": ($cpu|tonumber), "mem_percent": ($mem|tonumber), "command": $cmd}]')
    done < <(ps -eo pid,%cpu,%mem,comm --sort="$sort_key" | tail -n +2 | head -n "$count")
  fi

  echo "$processes"
}

# 收集所有系統指標
# 回傳完整的 JSON 物件
collect_all_system() {
  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local hostname
  hostname=$(hostname)

  local cpu mem disk load top_cpu top_mem
  cpu=$(collect_cpu)
  mem=$(collect_memory)
  disk=$(collect_disk)
  load=$(collect_load)
  top_cpu=$(collect_top_processes 5 cpu)
  top_mem=$(collect_top_processes 5 mem)

  cat <<EOF
{
  "timestamp": "$timestamp",
  "hostname": "$hostname",
  "cpu": $cpu,
  "memory": $mem,
  "disks": $disk,
  "load": $load,
  "top_processes_cpu": $top_cpu,
  "top_processes_mem": $top_mem
}
EOF
}

# 快速健康檢查（只回傳關鍵數值）
collect_system_summary() {
  local cpu_usage mem_usage disk_max_usage load1

  local cpu_json mem_json disk_json load_json
  cpu_json=$(collect_cpu)
  mem_json=$(collect_memory)
  disk_json=$(collect_disk)
  load_json=$(collect_load)

  cpu_usage=$(echo "$cpu_json" | jq -r '.usage_percent')
  mem_usage=$(echo "$mem_json" | jq -r '.usage_percent')
  disk_max_usage=$(echo "$disk_json" | jq -r '[.[].usage_percent] | max // 0')
  load1=$(echo "$load_json" | jq -r '.load_1m')

  printf '{"cpu_percent": %s, "memory_percent": %s, "disk_max_percent": %s, "load_1m": %s}' \
    "$cpu_usage" "$mem_usage" "$disk_max_usage" "$load1"
}
