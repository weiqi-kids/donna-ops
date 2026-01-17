#!/usr/bin/env bash
###############################################
# remediation/actions/kill-runaway.sh
# Description: 終止佔用過多資源的失控程序
# Risk Level: medium
# Auto-executable: false
###############################################

# 設定
CPU_THRESHOLD="${CPU_THRESHOLD:-90}"      # CPU 使用率閾值 (%)
MEM_THRESHOLD="${MEM_THRESHOLD:-50}"      # 記憶體使用率閾值 (%)
RUNTIME_THRESHOLD="${RUNTIME_THRESHOLD:-3600}"  # 執行時間閾值 (秒)

# 受保護的程序（不會被終止）
PROTECTED_PROCESSES=(
  "init"
  "systemd"
  "dockerd"
  "containerd"
  "sshd"
  "bash"
  "sh"
  "zsh"
  "journald"
  "rsyslogd"
  "cron"
  "crond"
  "udevd"
  "dbus-daemon"
  "NetworkManager"
  "postgres"
  "mysql"
  "redis-server"
  "nginx"
  "apache2"
  "httpd"
)

# 驗證動作
action_validate() {
  local target="$1"

  if [[ -n "$target" ]]; then
    # 如果指定了目標 PID 或名稱
    if [[ "$target" =~ ^[0-9]+$ ]]; then
      # PID
      if ! kill -0 "$target" 2>/dev/null; then
        echo "程序不存在: PID $target"
        return 1
      fi
    fi
  fi

  return 0
}

# 檢查程序是否受保護
_is_protected() {
  local proc_name="$1"

  for protected in "${PROTECTED_PROCESSES[@]}"; do
    if [[ "$proc_name" == "$protected" ]]; then
      return 0
    fi
  done

  return 1
}

# 取得失控程序清單
_get_runaway_processes() {
  local sort_by="${1:-cpu}"  # cpu 或 mem

  local processes="[]"

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS
    while IFS= read -r line; do
      local pid cpu mem cmd
      read -r pid cpu mem cmd <<< "$line"

      # 檢查是否超過閾值
      local over_threshold=false
      if (( $(echo "$cpu > $CPU_THRESHOLD" | bc -l 2>/dev/null || echo 0) )) || \
         (( $(echo "$mem > $MEM_THRESHOLD" | bc -l 2>/dev/null || echo 0) )); then
        over_threshold=true
      fi

      if [[ "$over_threshold" == "true" ]]; then
        if ! _is_protected "$cmd"; then
          processes=$(echo "$processes" | jq \
            --argjson pid "$pid" --arg cpu "$cpu" --arg mem "$mem" --arg cmd "$cmd" \
            '. + [{"pid": $pid, "cpu": ($cpu|tonumber), "mem": ($mem|tonumber), "command": $cmd}]')
        fi
      fi
    done < <(ps -Ao pid,%cpu,%mem,comm -r | tail -n +2 | head -20)
  else
    # Linux
    local sort_flag="-%cpu"
    [[ "$sort_by" == "mem" ]] && sort_flag="-%mem"

    while IFS= read -r line; do
      local pid cpu mem etime cmd
      read -r pid cpu mem etime cmd <<< "$line"

      # 解析執行時間
      local runtime_sec=0
      if [[ "$etime" =~ ^([0-9]+)-([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        # DD-HH:MM:SS
        runtime_sec=$(( ${BASH_REMATCH[1]} * 86400 + ${BASH_REMATCH[2]} * 3600 + ${BASH_REMATCH[3]} * 60 + ${BASH_REMATCH[4]} ))
      elif [[ "$etime" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        # HH:MM:SS
        runtime_sec=$(( ${BASH_REMATCH[1]} * 3600 + ${BASH_REMATCH[2]} * 60 + ${BASH_REMATCH[3]} ))
      elif [[ "$etime" =~ ^([0-9]+):([0-9]+)$ ]]; then
        # MM:SS
        runtime_sec=$(( ${BASH_REMATCH[1]} * 60 + ${BASH_REMATCH[2]} ))
      fi

      # 檢查是否超過閾值
      local over_threshold=false
      if (( $(echo "$cpu > $CPU_THRESHOLD" | bc -l 2>/dev/null || echo 0) )) || \
         (( $(echo "$mem > $MEM_THRESHOLD" | bc -l 2>/dev/null || echo 0) )); then
        # 高資源使用且執行時間超過閾值
        if (( runtime_sec > RUNTIME_THRESHOLD )); then
          over_threshold=true
        fi
      fi

      if [[ "$over_threshold" == "true" ]]; then
        if ! _is_protected "$cmd"; then
          processes=$(echo "$processes" | jq \
            --argjson pid "$pid" --arg cpu "$cpu" --arg mem "$mem" \
            --argjson runtime "$runtime_sec" --arg cmd "$cmd" \
            '. + [{"pid": $pid, "cpu": ($cpu|tonumber), "mem": ($mem|tonumber), "runtime_sec": $runtime, "command": $cmd}]')
        fi
      fi
    done < <(ps -eo pid,%cpu,%mem,etime,comm --sort="$sort_flag" | tail -n +2 | head -30)
  fi

  echo "$processes"
}

# 執行動作
action_execute() {
  local target="$1"
  local signal="${2:-TERM}"  # TERM 或 KILL

  echo "開始處理失控程序..."

  local killed=0
  local failed=0

  if [[ -n "$target" ]]; then
    # 終止指定的程序
    if [[ "$target" =~ ^[0-9]+$ ]]; then
      # PID
      local cmd
      cmd=$(ps -p "$target" -o comm= 2>/dev/null)

      if _is_protected "$cmd"; then
        echo "錯誤: $cmd (PID $target) 是受保護的程序"
        return 1
      fi

      echo "終止程序: PID $target ($cmd)"
      if kill -"$signal" "$target" 2>/dev/null; then
        ((killed++))
        echo "已發送 $signal 信號"
      else
        ((failed++))
        echo "發送信號失敗"
      fi
    else
      # 程序名稱
      if _is_protected "$target"; then
        echo "錯誤: $target 是受保護的程序"
        return 1
      fi

      echo "終止程序: $target"
      pkill -"$signal" "$target" 2>/dev/null && ((killed++)) || ((failed++))
    fi
  else
    # 自動偵測並終止失控程序
    local runaway_procs
    runaway_procs=$(_get_runaway_processes)

    if [[ "$runaway_procs" == "[]" ]]; then
      echo "沒有偵測到失控程序"
      return 0
    fi

    echo "偵測到以下失控程序："
    echo "$runaway_procs" | jq -r '.[] | "  PID \(.pid): \(.command) (CPU: \(.cpu)%, MEM: \(.mem)%)"'
    echo ""

    # 只處理前 3 個
    local count=0
    while IFS= read -r proc; do
      [[ -z "$proc" || "$proc" == "null" ]] && continue
      (( count >= 3 )) && break

      local pid cmd
      pid=$(echo "$proc" | jq -r '.pid')
      cmd=$(echo "$proc" | jq -r '.command')

      echo "終止: PID $pid ($cmd)"

      # 先嘗試 SIGTERM
      if kill -TERM "$pid" 2>/dev/null; then
        sleep 2
        # 檢查是否還在執行
        if kill -0 "$pid" 2>/dev/null; then
          echo "程序未回應 SIGTERM，發送 SIGKILL..."
          kill -KILL "$pid" 2>/dev/null || true
        fi
        ((killed++))
      else
        ((failed++))
      fi

      ((count++))
    done < <(echo "$runaway_procs" | jq -c '.[]' 2>/dev/null)
  fi

  echo ""
  echo "處理完成: 終止 $killed 個程序，失敗 $failed 個"

  if (( failed > 0 )); then
    return 1
  fi
  return 0
}

# 驗證結果
action_verify() {
  local target="$1"

  if [[ -n "$target" && "$target" =~ ^[0-9]+$ ]]; then
    # 檢查指定 PID 是否還存在
    if kill -0 "$target" 2>/dev/null; then
      echo "警告: 程序 PID $target 仍在執行"
      return 1
    else
      echo "程序 PID $target 已終止"
      return 0
    fi
  fi

  # 檢查是否還有失控程序
  local runaway_procs
  runaway_procs=$(_get_runaway_processes)
  local count
  count=$(echo "$runaway_procs" | jq 'length')

  if (( count > 0 )); then
    echo "警告: 仍有 $count 個程序可能失控"
    echo "$runaway_procs" | jq -r '.[] | "  PID \(.pid): \(.command)"'
    return 1
  fi

  echo "系統正常，沒有失控程序"
  return 0
}
