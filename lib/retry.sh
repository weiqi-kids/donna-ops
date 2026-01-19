#!/usr/bin/env bash
###############################################
# lib/retry.sh
# 重試機制模組
#
# 功能：
#   - 提供 exponential backoff 重試機制
#   - 支援自定義重試次數和延遲
#   - 記錄重試日誌
#
# 函式：
#   retry()                 通用重試函式
#   retry_curl()            curl 專用重試
#   retry_api_call()        API 呼叫重試
###############################################

if [[ -n "${RETRY_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RETRY_SH_LOADED=1

# 預設設定
declare -g RETRY_MAX_ATTEMPTS="${RETRY_MAX_ATTEMPTS:-4}"
declare -g RETRY_INITIAL_DELAY="${RETRY_INITIAL_DELAY:-2}"  # 秒
declare -g RETRY_MAX_DELAY="${RETRY_MAX_DELAY:-30}"          # 秒
declare -g RETRY_BACKOFF_MULTIPLIER="${RETRY_BACKOFF_MULTIPLIER:-2}"

# 通用重試函式
# 用法: retry [options] -- command [args...]
# 選項:
#   -n, --max-attempts N   最大重試次數（預設 4）
#   -d, --initial-delay N  初始延遲秒數（預設 2）
#   -m, --max-delay N      最大延遲秒數（預設 30）
# 範例: retry -n 3 -d 1 -- curl -s http://example.com
retry() {
  local max_attempts="$RETRY_MAX_ATTEMPTS"
  local initial_delay="$RETRY_INITIAL_DELAY"
  local max_delay="$RETRY_MAX_DELAY"
  local multiplier="$RETRY_BACKOFF_MULTIPLIER"

  # 解析選項
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--max-attempts)
        max_attempts="$2"
        shift 2
        ;;
      -d|--initial-delay)
        initial_delay="$2"
        shift 2
        ;;
      -m|--max-delay)
        max_delay="$2"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  local cmd=("$@")
  local attempt=1
  local delay="$initial_delay"
  local output
  local exit_code

  while (( attempt <= max_attempts )); do
    # 執行命令
    output=$("${cmd[@]}" 2>&1)
    exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
      echo "$output"
      return 0
    fi

    # 記錄重試
    if declare -f log_debug >/dev/null 2>&1; then
      log_debug "[Retry] 嘗試 $attempt/$max_attempts 失敗，${delay}s 後重試..."
    fi

    # 如果是最後一次嘗試，不需要等待
    if (( attempt >= max_attempts )); then
      break
    fi

    # 等待
    sleep "$delay"

    # 計算下次延遲（exponential backoff）
    delay=$((delay * multiplier))
    if (( delay > max_delay )); then
      delay="$max_delay"
    fi

    ((attempt++))
  done

  # 所有嘗試都失敗
  if declare -f log_warn >/dev/null 2>&1; then
    log_warn "[Retry] 命令失敗（嘗試 $max_attempts 次）: ${cmd[*]}"
  fi

  echo "$output"
  return "$exit_code"
}

# curl 專用重試
# 用法: retry_curl [curl_options...]
# 範例: retry_curl -s -H "Authorization: token xxx" https://api.github.com/user
retry_curl() {
  local max_attempts="$RETRY_MAX_ATTEMPTS"
  local initial_delay="$RETRY_INITIAL_DELAY"
  local max_delay="$RETRY_MAX_DELAY"
  local multiplier="$RETRY_BACKOFF_MULTIPLIER"

  local attempt=1
  local delay="$initial_delay"
  local output
  local http_code
  local curl_exit

  while (( attempt <= max_attempts )); do
    # 執行 curl，同時取得 HTTP 狀態碼
    local response
    response=$(curl -w "\n__HTTP_CODE__:%{http_code}" "$@" 2>&1)
    curl_exit=$?

    # 分離輸出和 HTTP 狀態碼
    output=$(echo "$response" | sed '$d')
    http_code=$(echo "$response" | tail -n1 | sed 's/__HTTP_CODE__://')

    # 檢查是否成功
    if [[ $curl_exit -eq 0 ]]; then
      # curl 成功，檢查 HTTP 狀態碼
      case "$http_code" in
        2*|3*)
          # 2xx 或 3xx 成功
          echo "$output"
          return 0
          ;;
        429|500|502|503|504)
          # 可重試的錯誤
          if declare -f log_debug >/dev/null 2>&1; then
            log_debug "[Retry] HTTP $http_code，${delay}s 後重試..."
          fi
          ;;
        4*)
          # 4xx 客戶端錯誤（除了 429），不重試
          echo "$output"
          return 1
          ;;
      esac
    else
      # curl 執行失敗（網路錯誤等）
      if declare -f log_debug >/dev/null 2>&1; then
        log_debug "[Retry] curl 失敗 (exit $curl_exit)，${delay}s 後重試..."
      fi
    fi

    # 如果是最後一次嘗試，不需要等待
    if (( attempt >= max_attempts )); then
      break
    fi

    # 等待
    sleep "$delay"

    # 計算下次延遲
    delay=$((delay * multiplier))
    if (( delay > max_delay )); then
      delay="$max_delay"
    fi

    ((attempt++))
  done

  # 所有嘗試都失敗
  if declare -f log_warn >/dev/null 2>&1; then
    log_warn "[Retry] curl 失敗（嘗試 $max_attempts 次）"
  fi

  echo "$output"
  return 1
}

# API 呼叫重試（包裝 gh 和其他 API 工具）
# 用法: retry_api_call command [args...]
# 範例: retry_api_call gh issue list --repo owner/repo
retry_api_call() {
  retry -n "$RETRY_MAX_ATTEMPTS" -d "$RETRY_INITIAL_DELAY" -- "$@"
}

# 設定重試參數
retry_set_max_attempts() {
  RETRY_MAX_ATTEMPTS="$1"
}

retry_set_initial_delay() {
  RETRY_INITIAL_DELAY="$1"
}

retry_set_max_delay() {
  RETRY_MAX_DELAY="$1"
}

# 初始化重試模組（從配置讀取設定）
retry_init() {
  local max_attempts="${1:-4}"
  local initial_delay="${2:-2}"
  local max_delay="${3:-30}"

  RETRY_MAX_ATTEMPTS="$max_attempts"
  RETRY_INITIAL_DELAY="$initial_delay"
  RETRY_MAX_DELAY="$max_delay"
}
