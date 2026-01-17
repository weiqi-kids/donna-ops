#!/usr/bin/env bash
###############################################
# config.sh
# YAML 設定檔解析功能
#   - config_load()     載入 config.yaml
#   - config_get()      取得設定值
#   - config_validate() 驗證必填欄位
#
# 依賴：yq (https://github.com/mikefarah/yq)
###############################################

if [[ -n "${CONFIG_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
CONFIG_SH_LOADED=1

# 全域變數
declare -g CONFIG_FILE=""
declare -g CONFIG_LOADED=""

# 載入設定檔
# 用法：config_load "/path/to/config.yaml"
config_load() {
  local config_path="${1:-}"

  if [[ -z "$config_path" ]]; then
    # 嘗試預設路徑
    local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    config_path="${script_dir}/config/config.yaml"
  fi

  if [[ ! -f "$config_path" ]]; then
    echo "ERROR: 設定檔不存在：$config_path" >&2
    return 1
  fi

  # 檢查 yq 是否可用
  if ! command -v yq >/dev/null 2>&1; then
    echo "ERROR: 缺少 yq 指令，請先安裝" >&2
    return 1
  fi

  # 驗證 YAML 格式
  if ! yq eval '.' "$config_path" >/dev/null 2>&1; then
    echo "ERROR: YAML 格式錯誤：$config_path" >&2
    return 1
  fi

  CONFIG_FILE="$config_path"
  CONFIG_LOADED="1"
  return 0
}

# 取得設定值
# 用法：config_get "thresholds.cpu_percent"
# 回傳：設定值（若不存在則為空字串）
config_get() {
  local key="$1"
  local default="${2:-}"

  if [[ -z "$CONFIG_LOADED" || -z "$CONFIG_FILE" ]]; then
    echo "ERROR: 設定檔尚未載入，請先呼叫 config_load()" >&2
    return 1
  fi

  local value
  value=$(yq eval ".${key} // \"\"" "$CONFIG_FILE" 2>/dev/null)

  # yq 對於 null 會回傳 "null" 字串
  if [[ "$value" == "null" || -z "$value" ]]; then
    echo "$default"
  else
    echo "$value"
  fi
}

# 取得設定值（整數，支援負數）
config_get_int() {
  local key="$1"
  local default="${2:-0}"

  local value
  value=$(config_get "$key" "$default")

  # 確保是數字（支援負數）
  if [[ "$value" =~ ^-?[0-9]+$ ]]; then
    echo "$value"
  else
    echo "$default"
  fi
}

# 取得設定值（布林）
config_get_bool() {
  local key="$1"
  local default="${2:-false}"

  local value
  value=$(config_get "$key" "$default")

  case "${value,,}" in
    true|yes|1|on)  echo "true" ;;
    false|no|0|off) echo "false" ;;
    *)              echo "$default" ;;
  esac
}

# 取得陣列設定
# 用法：config_get_array "notifications.channels"
config_get_array() {
  local key="$1"

  if [[ -z "$CONFIG_LOADED" || -z "$CONFIG_FILE" ]]; then
    echo "ERROR: 設定檔尚未載入" >&2
    return 1
  fi

  yq eval ".${key}[]" "$CONFIG_FILE" 2>/dev/null || true
}

# 驗證必填欄位
# 用法：config_validate "host_name" "linode_api_token" "github_repo"
config_validate() {
  local missing=()

  for key in "$@"; do
    local value
    value=$(config_get "$key")
    if [[ -z "$value" ]]; then
      missing+=("$key")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: 缺少必填設定欄位：" >&2
    for key in "${missing[@]}"; do
      echo "  - $key" >&2
    done
    return 1
  fi

  return 0
}

# 檢查設定是否存在
config_has() {
  local key="$1"
  local value
  value=$(config_get "$key")
  [[ -n "$value" ]]
}

# 印出所有設定（除錯用）
config_dump() {
  if [[ -z "$CONFIG_LOADED" || -z "$CONFIG_FILE" ]]; then
    echo "ERROR: 設定檔尚未載入" >&2
    return 1
  fi

  echo "=== Config: $CONFIG_FILE ==="
  yq eval '.' "$CONFIG_FILE"
}

# 從 git remote 自動偵測 GitHub repo
# 用法：config_detect_github_repo [directory]
# 回傳：owner/repo 格式，或空字串
config_detect_github_repo() {
  local dir="${1:-.}"

  if ! command -v git >/dev/null 2>&1; then
    return 1
  fi

  local remote_url
  remote_url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1

  # 解析 GitHub URL
  # 支援格式：
  #   https://github.com/owner/repo.git
  #   https://github.com/owner/repo
  #   git@github.com:owner/repo.git
  #   git@github.com:owner/repo
  local repo=""

  if [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
    repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi

  echo "$repo"
}

# 取得 github_repo 設定（支援自動偵測）
# 優先使用設定檔，若為空或 "auto" 則自動偵測
config_get_github_repo() {
  local value
  value=$(config_get "github_repo" "")

  if [[ -z "$value" || "$value" == "auto" ]]; then
    # 嘗試自動偵測
    value=$(config_detect_github_repo)
  fi

  echo "$value"
}
