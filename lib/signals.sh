#!/usr/bin/env bash
###############################################
# lib/signals.sh
# 信號處理模組（Graceful Shutdown）
#
# 功能：
#   - 統一處理 SIGTERM/SIGINT/SIGHUP 信號
#   - 確保資源正確釋放
#   - 支援自定義清理函式
#
# 函式：
#   signals_init()          初始化信號處理
#   signals_register()      註冊清理函式
#   signals_shutdown()      執行關閉流程
###############################################

if [[ -n "${SIGNALS_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
SIGNALS_SH_LOADED=1

# 狀態
declare -g SIGNALS_SHUTDOWN_IN_PROGRESS="false"
declare -g SIGNALS_SHUTDOWN_TIMEOUT=30  # 秒
declare -ga SIGNALS_CLEANUP_HANDLERS=()
declare -ga SIGNALS_CHILD_PIDS=()

# 初始化信號處理
# 用法: signals_init [shutdown_timeout]
signals_init() {
  local timeout="${1:-30}"
  SIGNALS_SHUTDOWN_TIMEOUT="$timeout"

  # 設定信號處理器
  trap '_signals_handle SIGTERM' SIGTERM
  trap '_signals_handle SIGINT' SIGINT
  trap '_signals_handle SIGHUP' SIGHUP

  # 設定 EXIT 處理（確保清理）
  trap '_signals_on_exit' EXIT
}

# 註冊清理函式
# 用法: signals_register cleanup_function
# 清理函式會在關閉時依序執行（後註冊的先執行）
signals_register() {
  local handler="$1"
  SIGNALS_CLEANUP_HANDLERS+=("$handler")
}

# 註冊子程序 PID（關閉時會終止）
# 用法: signals_register_child pid
signals_register_child() {
  local pid="$1"
  SIGNALS_CHILD_PIDS+=("$pid")
}

# 移除子程序 PID
# 用法: signals_unregister_child pid
signals_unregister_child() {
  local pid="$1"
  local new_pids=()
  for p in "${SIGNALS_CHILD_PIDS[@]}"; do
    [[ "$p" != "$pid" ]] && new_pids+=("$p")
  done
  SIGNALS_CHILD_PIDS=("${new_pids[@]}")
}

# 內部：信號處理器
_signals_handle() {
  local signal="$1"

  # 避免重複處理
  if [[ "$SIGNALS_SHUTDOWN_IN_PROGRESS" == "true" ]]; then
    return
  fi
  SIGNALS_SHUTDOWN_IN_PROGRESS="true"

  if declare -f log_info >/dev/null 2>&1; then
    log_info "[Signals] 收到 $signal 信號，開始優雅關閉..."
  else
    echo "[Signals] 收到 $signal 信號，開始優雅關閉..." >&2
  fi

  # 執行關閉流程
  _signals_shutdown "$signal"

  # 根據信號決定退出碼
  case "$signal" in
    SIGTERM) exit 143 ;;  # 128 + 15
    SIGINT)  exit 130 ;;  # 128 + 2
    SIGHUP)  exit 129 ;;  # 128 + 1
    *)       exit 1 ;;
  esac
}

# 內部：執行關閉流程
_signals_shutdown() {
  local signal="${1:-SIGTERM}"
  local start_time
  start_time=$(date +%s)

  # Step 1: 終止子程序
  if (( ${#SIGNALS_CHILD_PIDS[@]} > 0 )); then
    if declare -f log_info >/dev/null 2>&1; then
      log_info "[Signals] 終止 ${#SIGNALS_CHILD_PIDS[@]} 個子程序..."
    fi

    for pid in "${SIGNALS_CHILD_PIDS[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        # 先發送 SIGTERM
        kill -TERM "$pid" 2>/dev/null || true
      fi
    done

    # 等待子程序結束（最多 5 秒）
    local wait_count=0
    while (( wait_count < 50 )); do
      local all_dead="true"
      for pid in "${SIGNALS_CHILD_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
          all_dead="false"
          break
        fi
      done
      [[ "$all_dead" == "true" ]] && break
      sleep 0.1
      ((wait_count++))
    done

    # 如果還有存活的子程序，強制終止
    for pid in "${SIGNALS_CHILD_PIDS[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        if declare -f log_warn >/dev/null 2>&1; then
          log_warn "[Signals] 強制終止子程序 $pid"
        fi
        kill -KILL "$pid" 2>/dev/null || true
      fi
    done
  fi

  # Step 2: 執行清理函式（後註冊的先執行）
  if (( ${#SIGNALS_CLEANUP_HANDLERS[@]} > 0 )); then
    if declare -f log_info >/dev/null 2>&1; then
      log_info "[Signals] 執行 ${#SIGNALS_CLEANUP_HANDLERS[@]} 個清理函式..."
    fi

    # 反向執行
    for ((i=${#SIGNALS_CLEANUP_HANDLERS[@]}-1; i>=0; i--)); do
      local handler="${SIGNALS_CLEANUP_HANDLERS[$i]}"

      # 檢查是否超時
      local elapsed
      elapsed=$(($(date +%s) - start_time))
      if (( elapsed >= SIGNALS_SHUTDOWN_TIMEOUT )); then
        if declare -f log_warn >/dev/null 2>&1; then
          log_warn "[Signals] 關閉超時，跳過剩餘清理函式"
        fi
        break
      fi

      # 執行清理函式
      if declare -f "$handler" >/dev/null 2>&1; then
        if declare -f log_debug >/dev/null 2>&1; then
          log_debug "[Signals] 執行清理: $handler"
        fi
        "$handler" || true
      fi
    done
  fi

  # Step 3: 釋放鎖
  if declare -f state_unlock >/dev/null 2>&1; then
    state_unlock 2>/dev/null || true
  fi

  if declare -f log_info >/dev/null 2>&1; then
    log_info "[Signals] 優雅關閉完成"
  fi
}

# 內部：EXIT 處理（確保清理）
_signals_on_exit() {
  # 如果不是正常關閉流程，執行清理
  if [[ "$SIGNALS_SHUTDOWN_IN_PROGRESS" != "true" ]]; then
    _signals_shutdown "EXIT"
  fi
}

# 手動觸發關閉
# 用法: signals_shutdown [exit_code]
signals_shutdown() {
  local exit_code="${1:-0}"

  if [[ "$SIGNALS_SHUTDOWN_IN_PROGRESS" == "true" ]]; then
    return
  fi
  SIGNALS_SHUTDOWN_IN_PROGRESS="true"

  _signals_shutdown "MANUAL"
  exit "$exit_code"
}

# 檢查是否正在關閉中
signals_is_shutting_down() {
  [[ "$SIGNALS_SHUTDOWN_IN_PROGRESS" == "true" ]]
}

# 設定關閉超時
signals_set_timeout() {
  SIGNALS_SHUTDOWN_TIMEOUT="$1"
}
