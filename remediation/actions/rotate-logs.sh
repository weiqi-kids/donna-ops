#!/usr/bin/env bash
###############################################
# remediation/actions/rotate-logs.sh
# Description: 輪替日誌檔案以釋放磁碟空間
# Risk Level: low
# Auto-executable: true
###############################################

# 設定
LOG_DIRS=(
  "/var/log"
  "/opt/donna-ops/logs"
)
MAX_LOG_AGE_DAYS="${MAX_LOG_AGE_DAYS:-7}"
MAX_LOG_SIZE_MB="${MAX_LOG_SIZE_MB:-100}"

# 驗證動作
action_validate() {
  # 檢查是否有 logrotate 或基本工具
  if ! command -v find >/dev/null 2>&1; then
    echo "找不到 find 命令"
    return 1
  fi
  return 0
}

# 執行動作
action_execute() {
  local target="${1:-all}"
  local freed_space=0

  echo "開始日誌輪替..."

  # 1. 使用 logrotate（如果可用）
  if command -v logrotate >/dev/null 2>&1 && [[ -f /etc/logrotate.conf ]]; then
    echo "執行 logrotate..."
    sudo logrotate -f /etc/logrotate.conf 2>&1 || true
  fi

  # 2. 清理舊的日誌檔案
  echo "清理超過 ${MAX_LOG_AGE_DAYS} 天的日誌..."
  for dir in "${LOG_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
      # 刪除舊的 .log 和壓縮檔
      local old_files
      old_files=$(find "$dir" -type f \( -name "*.log.*" -o -name "*.gz" -o -name "*.xz" -o -name "*.bz2" \) -mtime +${MAX_LOG_AGE_DAYS} 2>/dev/null)
      if [[ -n "$old_files" ]]; then
        local size_before
        size_before=$(echo "$old_files" | xargs du -sc 2>/dev/null | tail -1 | awk '{print $1}')
        echo "$old_files" | xargs rm -f 2>/dev/null || true
        freed_space=$((freed_space + ${size_before:-0}))
        echo "從 $dir 清理了 $((${size_before:-0} / 1024)) MB"
      fi
    fi
  done

  # 3. 截斷過大的日誌檔
  echo "截斷超過 ${MAX_LOG_SIZE_MB} MB 的日誌..."
  for dir in "${LOG_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
      while IFS= read -r logfile; do
        [[ -z "$logfile" ]] && continue
        local size_mb
        size_mb=$(du -m "$logfile" 2>/dev/null | awk '{print $1}')
        if (( size_mb > MAX_LOG_SIZE_MB )); then
          echo "截斷: $logfile (${size_mb} MB)"
          # 保留最後 1000 行
          tail -n 1000 "$logfile" > "${logfile}.tmp" 2>/dev/null
          cat "${logfile}.tmp" > "$logfile" 2>/dev/null
          rm -f "${logfile}.tmp"
          freed_space=$((freed_space + (size_mb - 1) * 1024))
        fi
      done < <(find "$dir" -type f -name "*.log" -size +${MAX_LOG_SIZE_MB}M 2>/dev/null)
    fi
  done

  # 4. 清理 journald（如果可用）
  if command -v journalctl >/dev/null 2>&1; then
    echo "清理 journald 舊日誌..."
    sudo journalctl --vacuum-time=${MAX_LOG_AGE_DAYS}d 2>&1 || true
    sudo journalctl --vacuum-size=500M 2>&1 || true
  fi

  # 5. 清理 Docker 容器日誌（如果 target 包含 docker）
  if [[ "$target" == "all" || "$target" == "docker" ]]; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      echo "清理 Docker 容器日誌..."
      # 找到所有容器的日誌檔案
      for container_id in $(docker ps -aq 2>/dev/null); do
        local log_path
        log_path=$(docker inspect --format='{{.LogPath}}' "$container_id" 2>/dev/null)
        if [[ -n "$log_path" && -f "$log_path" ]]; then
          local size_mb
          size_mb=$(du -m "$log_path" 2>/dev/null | awk '{print $1}')
          if (( size_mb > MAX_LOG_SIZE_MB )); then
            echo "截斷容器日誌: $container_id (${size_mb} MB)"
            sudo truncate -s 0 "$log_path" 2>/dev/null || true
            freed_space=$((freed_space + size_mb * 1024))
          fi
        fi
      done
    fi
  fi

  echo "日誌輪替完成，共釋放約 $((freed_space / 1024)) MB"
  return 0
}

# 驗證結果
action_verify() {
  # 檢查磁碟使用率是否下降
  local usage
  usage=$(df -k / | tail -1 | awk '{print $5}' | tr -d '%')
  echo "目前根目錄使用率: ${usage}%"

  if (( usage < 90 )); then
    return 0
  else
    echo "警告: 磁碟使用率仍然較高"
    return 1
  fi
}
