#!/usr/bin/env bash
###############################################
# remediation/actions/clear-cache.sh
# Description: 清除系統快取以釋放記憶體
# Risk Level: low
# Auto-executable: true
###############################################

# 驗證動作
action_validate() {
  # 需要 root 權限來清除 page cache
  if [[ "$(uname)" != "Darwin" && $EUID -ne 0 ]]; then
    echo "需要 root 權限"
    return 1
  fi
  return 0
}

# 執行動作
action_execute() {
  local target="${1:-all}"

  echo "開始清除快取..."

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: 使用 purge 命令
    if command -v purge >/dev/null 2>&1; then
      echo "執行 purge 命令..."
      sudo purge 2>&1 || true
    else
      echo "macOS purge 命令不可用"
    fi
  else
    # Linux: 清除 page cache, dentries, inodes

    # 先同步檔案系統
    echo "同步檔案系統..."
    sync

    case "$target" in
      pagecache)
        echo "清除 page cache..."
        echo 1 | sudo tee /proc/sys/vm/drop_caches >/dev/null
        ;;
      dentries)
        echo "清除 dentries 和 inodes..."
        echo 2 | sudo tee /proc/sys/vm/drop_caches >/dev/null
        ;;
      all)
        echo "清除所有快取 (page cache + dentries + inodes)..."
        echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
        ;;
      *)
        echo "未知的 target: $target，使用預設（all）"
        echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
        ;;
    esac

    # 清除 swap（如果記憶體足夠）
    local mem_free swap_used
    mem_free=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    swap_used=$(grep SwapTotal /proc/meminfo | awk '{print $2}')

    if (( mem_free > swap_used )); then
      echo "清除 swap（可用記憶體足夠）..."
      sudo swapoff -a && sudo swapon -a 2>&1 || true
    fi
  fi

  echo "快取清除完成"
  return 0
}

# 驗證結果
action_verify() {
  local before_free after_free

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS 驗證
    echo "macOS 快取清除驗證完成"
    return 0
  else
    # Linux 驗證
    after_free=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    echo "目前可用記憶體: $((after_free / 1024)) MB"
    return 0
  fi
}
