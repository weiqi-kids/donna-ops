#!/usr/bin/env bash

###############################################
# core.sh
# 通用輔助函式：
#   - require_cmd <cmd>  檢查必要指令是否存在，並給出安裝提示
#   - require_dep <path> 檢查必要檔案是否存在，回傳實際路徑
#
# 使用方式（在入口腳本中）：
#   source ./lib/core.sh
#   require_cmd curl jq
#   some_path="$(require_dep ./config/.env)"
#
# 注意：
#   - 此檔案預期被其他腳本以 `source` 載入
#   - 請在「真正的入口腳本」自行設定：set -euo pipefail
###############################################

# 避免被重複載入（多次 source）
if [[ -n "${CORE_SH_LOADED:-}" ]]; then
  # 若是被 source，return 0 就好；若被誤執行，則 exit 0
  return 0 2>/dev/null || exit 0
fi
CORE_SH_LOADED=1

# 偵測 Linux 發行版（回傳字串）
_detect_linux_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release

    # 直接用 ID 判定
    case "$ID" in
      ubuntu)  echo "ubuntu"; return ;;
      debian)  echo "debian"; return ;;
      arch)    echo "arch"; return ;;
      alpine)  echo "alpine"; return ;;
      centos)  echo "centos"; return ;;
      rhel)    echo "rhel"; return ;;
      fedora)  echo "fedora"; return ;;
    esac

    # fallback → 用 ID_LIKE 判定
    case "${ID_LIKE:-}" in
      *debian*) echo "debian"; return ;;
      *rhel*)   echo "rhel"; return ;;
      *fedora*) echo "fedora"; return ;;
    esac
  fi

  echo "unknown"
}

# 專門給外部 script 用的 require_cmd
require_cmd() {
  local cmd="$1"

  # 若找到指令 → OK
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi

  echo "❌ 缺少必要指令：$cmd"
  echo "----------------------------------------"
  echo

  local UNAME="$(uname -s)"
  if [[ "$UNAME" == "Darwin" ]]; then
    echo "👉 使用 Homebrew 安裝："
    echo
    echo "    brew install ${cmd}"
    echo
    echo "若無 Homebrew，請先安裝："
    echo '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

  elif [[ "$UNAME" == "Linux" ]]; then
    local distro="$(_detect_linux_distro)"
    case "$distro" in
      ubuntu|debian)
        echo "👉 安裝指令："
        echo "    sudo apt-get update && sudo apt-get install -y ${cmd}"
        ;;
      centos|rhel)
        echo "👉 安裝指令："
        echo "    sudo yum install -y ${cmd}"
        ;;
      fedora)
        echo "👉 安裝指令："
        echo "    sudo dnf install -y ${cmd}"
        ;;
      arch)
        echo "👉 安裝指令："
        echo "    sudo pacman -S ${cmd}"
        ;;
      alpine)
        echo "👉 安裝指令："
        echo "    sudo apk add ${cmd}"
        ;;
      *)
        echo "⚠️ 無法辨識 Linux 發行版，請自行安裝：${cmd}"
        ;;
    esac
  else
    echo "請手動安裝：${cmd}"
  fi
  echo
  echo "----------------------------------------"
  echo "💥 缺少必要指令，任務停止"
  exit 1
}

# 檢查腳本檔 / 其他依賴檔案
require_dep() {
  local name="$1"
  local base_dir

  if [[ -n "${SCRIPT_DIR:-}" ]]; then
    base_dir="$SCRIPT_DIR"
  else
    base_dir="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
  fi

  local path="$name"

  if [[ "$path" != /* && "$path" != ./* && "$path" != ../* ]]; then
    path="${base_dir}/${path}"
  fi

  if [[ -f "$path" ]]; then
    echo "$path"
    return 0
  fi

  echo "❌ 找不到必要檔案：${name}"
  echo "🔍 預期路徑：${path}"
  echo "----------------------------------------"
  echo "請確認該檔案存在，或調整 SCRIPT_DIR"
  echo "💥 任務停止"
  exit 1
}
