#!/usr/bin/env bash
# 注意：此檔案預期被其他腳本以 `source ./lib/args.sh` 載入。
# 不在這裡 set -euo pipefail，交給呼叫端決定。

if [[ -n "${ARGS_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ARGS_SH_LOADED=1

###########################################################
# args.sh
#
# 提供三個工具：
#   1) parse_args "$@"
#        - 解析命令列參數，支援：
#            --id foo
#            --id=foo
#            --dry-run   (boolean flag)
#        - 解析後會產生全域變數：
#            ARG_id="foo"
#            ARG_dry_run="1"
#
#   2) arg_required <key> <var_name> <description>
#        - key       ：對應旗標名稱（不含 --），例如 "id" 對應 --id
#        - var_name  ：你程式內真正想用的變數名，例如 CONFIG_ID
#        - desc      ：缺少時顯示的說明文字
#
#   3) arg_optional <key> <var_name> <default_value>
#        - 選填參數，有給就用參數值，沒給就用預設值
###########################################################

########################################
# parse_args：把 --key value 變成 ARG_key
########################################
parse_args() {
  unset ARG_POSITIONALS || true

  # 清掉舊的 ARG_* 變數，避免上一輪 parse 結果殘留
  local v
  while IFS= read -r v; do
    unset "$v"
  done < <(compgen -v ARG_ || true)

  while (( $# > 0 )); do
    case "$1" in
      --*=*)
        # 形式：--id=my_id
        local key="${1%%=*}"   # --id
        local val="${1#*=}"    # my_id
        key="${key#--}"        # id
        local var="ARG_${key//-/_}"
        printf -v "$var" '%s' "$val"
        ;;
      --*)
        # 形式：--id my_id 或 --dry-run
        local key="${1#--}"               # id / dry-run
        local var="ARG_${key//-/_}"       # ARG_id / ARG_dry_run

        # 看下一個是不是值（不是另一個 --flag）
        if [[ $# -ge 2 && ! "$2" =~ ^-- ]]; then
          local val="$2"
          printf -v "$var" '%s' "$val"
          shift
        else
          # 視為 boolean flag
          printf -v "$var" '%s' "1"
        fi
        ;;
      *)
        # 這裡是「位置參數」（非 -- 開頭），看你之後要不要用
        # 先丟進 ARG_POSITIONALS
        if [[ -z "${ARG_POSITIONALS:-}" ]]; then
          ARG_POSITIONALS="$1"
        else
          ARG_POSITIONALS+=" $1"
        fi
        ;;
    esac
    shift || true
  done
}

########################################
# arg_required：必填參數
#
# 用法：
#   arg_required id   CONFIG_ID "說明文字..."
#   arg_required file FILE_PATH "說明文字..."
########################################
arg_required() {
  local key="$1"        # 如：id
  local var_name="$2"   # 如：CONFIG_ID
  local desc="$3"       # 如：會讀取同目錄下...

  local arg_var="ARG_${key//-/_}"   # ARG_id
  local val="${!arg_var-}"          # 取 ARG_id 的值（沒有就空字串）

  if [[ -z "${val}" ]]; then
    echo "❌ 缺少必要參數：--${key}" >&2
    if [[ -n "$desc" ]]; then
      echo "   說明：$desc" >&2
    fi
    exit 1
  fi

  # 把值塞進你要用的變數名（例如 CONFIG_ID）
  printf -v "$var_name" '%s' "$val"
}

########################################
# arg_optional：選填參數（可帶預設值）
#
# 用法：
#   arg_optional total TOTAL_SEC "8"
########################################
arg_optional() {
  local key="$1"        # 如：total
  local var_name="$2"   # 如：TOTAL_SEC
  local default="${3-}" # 預設值

  local arg_var="ARG_${key//-/_}"   # ARG_total
  local val="${!arg_var-}"

  if [[ -z "${val}" ]]; then
    val="$default"
  fi

  printf -v "$var_name" '%s' "$val"
}
