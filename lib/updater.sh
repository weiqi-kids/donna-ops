#!/usr/bin/env bash
###############################################
# lib/updater.sh
# 自動更新模組
#
# 功能：
#   - 檢查 GitHub 是否有新版本
#   - 自動拉取更新
#   - 更新後重啟服務
#
# 函式：
#   updater_init()              初始化更新器
#   check_for_updates()         檢查是否有更新
#   perform_update()            執行更新
#   auto_update_if_needed()     條件式自動更新
###############################################

if [[ -n "${UPDATER_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
UPDATER_SH_LOADED=1

# 更新器設定
declare -g UPDATER_ENABLED="false"
declare -g UPDATER_BRANCH="${UPDATER_BRANCH:-main}"
declare -g UPDATER_AUTO_RESTART="true"
declare -g UPDATER_CHECK_INTERVAL=60  # 分鐘
declare -g UPDATER_LAST_CHECK=0

# 初始化更新器
# 用法: updater_init [branch] [check_interval_minutes]
updater_init() {
  local branch="${1:-main}"
  local interval="${2:-60}"

  UPDATER_BRANCH="$branch"
  UPDATER_CHECK_INTERVAL="$interval"

  # 檢查是否在 git 目錄中
  if ! git -C "${SCRIPT_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
    echo "WARN: 不在 Git 儲存庫中，自動更新停用" >&2
    return 1
  fi

  # 檢查是否有 remote
  if ! git -C "${SCRIPT_DIR}" remote get-url origin >/dev/null 2>&1; then
    echo "WARN: 沒有設定 Git remote，自動更新停用" >&2
    return 1
  fi

  UPDATER_ENABLED="true"
  return 0
}

# 檢查是否有更新
# 用法: check_for_updates
# 輸出: JSON 格式的更新資訊
check_for_updates() {
  if [[ "$UPDATER_ENABLED" != "true" ]]; then
    echo '{"available": false, "error": "Updater not enabled"}'
    return 1
  fi

  local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

  # 取得目前的 commit
  local current_commit
  current_commit=$(git -C "$script_dir" rev-parse HEAD 2>/dev/null)
  if [[ -z "$current_commit" ]]; then
    echo '{"available": false, "error": "Cannot get current commit"}'
    return 1
  fi

  # 取得目前分支
  local current_branch
  current_branch=$(git -C "$script_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)

  # Fetch 最新的 remote 資訊
  if ! git -C "$script_dir" fetch origin "$UPDATER_BRANCH" --quiet 2>/dev/null; then
    echo '{"available": false, "error": "Cannot fetch from remote"}'
    return 1
  fi

  # 取得 remote 的最新 commit
  local remote_commit
  remote_commit=$(git -C "$script_dir" rev-parse "origin/${UPDATER_BRANCH}" 2>/dev/null)
  if [[ -z "$remote_commit" ]]; then
    echo '{"available": false, "error": "Cannot get remote commit"}'
    return 1
  fi

  # 比較
  if [[ "$current_commit" == "$remote_commit" ]]; then
    cat <<EOF
{
  "available": false,
  "current_commit": "${current_commit:0:8}",
  "remote_commit": "${remote_commit:0:8}",
  "branch": "$current_branch",
  "target_branch": "$UPDATER_BRANCH",
  "message": "Already up to date"
}
EOF
    return 0
  fi

  # 計算落後多少 commits
  local behind_count
  behind_count=$(git -C "$script_dir" rev-list --count "HEAD..origin/${UPDATER_BRANCH}" 2>/dev/null || echo "?")

  # 取得最新的 commit 訊息
  local latest_message
  latest_message=$(git -C "$script_dir" log -1 --format="%s" "origin/${UPDATER_BRANCH}" 2>/dev/null | head -c 100)

  cat <<EOF
{
  "available": true,
  "current_commit": "${current_commit:0:8}",
  "remote_commit": "${remote_commit:0:8}",
  "branch": "$current_branch",
  "target_branch": "$UPDATER_BRANCH",
  "behind_count": $behind_count,
  "latest_message": $(echo "$latest_message" | jq -Rs '.'),
  "message": "Update available"
}
EOF
}

# 執行更新
# 用法: perform_update [--force] [--no-restart]
# 返回: 0=成功, 1=失敗
perform_update() {
  local force="false"
  local do_restart="$UPDATER_AUTO_RESTART"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force="true"; shift ;;
      --no-restart) do_restart="false"; shift ;;
      *) shift ;;
    esac
  done

  if [[ "$UPDATER_ENABLED" != "true" ]]; then
    echo '{"success": false, "error": "Updater not enabled"}'
    return 1
  fi

  local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

  # 檢查是否有未提交的變更
  if [[ "$force" != "true" ]]; then
    local changes
    changes=$(git -C "$script_dir" status --porcelain 2>/dev/null)
    if [[ -n "$changes" ]]; then
      echo '{"success": false, "error": "Working directory has uncommitted changes", "hint": "Use --force to override"}'
      return 1
    fi
  fi

  # 記錄更新前的 commit
  local before_commit
  before_commit=$(git -C "$script_dir" rev-parse --short HEAD 2>/dev/null)

  # 執行更新
  local pull_result
  if [[ "$force" == "true" ]]; then
    # 強制更新：重設到 remote
    pull_result=$(git -C "$script_dir" fetch origin "$UPDATER_BRANCH" 2>&1 && \
                  git -C "$script_dir" reset --hard "origin/${UPDATER_BRANCH}" 2>&1)
  else
    # 正常更新：git pull
    pull_result=$(git -C "$script_dir" pull origin "$UPDATER_BRANCH" 2>&1)
  fi

  local pull_status=$?
  if [[ $pull_status -ne 0 ]]; then
    echo "{\"success\": false, \"error\": \"Git pull failed\", \"details\": $(echo "$pull_result" | jq -Rs '.')}"
    return 1
  fi

  # 記錄更新後的 commit
  local after_commit
  after_commit=$(git -C "$script_dir" rev-parse --short HEAD 2>/dev/null)

  # 檢查是否真的有更新
  if [[ "$before_commit" == "$after_commit" ]]; then
    cat <<EOF
{
  "success": true,
  "updated": false,
  "commit": "$after_commit",
  "message": "Already up to date"
}
EOF
    return 0
  fi

  # 取得更新的 commit 訊息
  local update_message
  update_message=$(git -C "$script_dir" log -1 --format="%s" 2>/dev/null | head -c 100)

  # 記錄到稽核日誌
  if declare -f log_audit >/dev/null 2>&1; then
    log_audit "auto-update" "donna-ops" "success" "Updated from $before_commit to $after_commit"
  fi

  # 回報到 GitHub（如果啟用）
  _report_update_to_github "$before_commit" "$after_commit" "$update_message"

  # 重啟服務
  local restart_result="skipped"
  if [[ "$do_restart" == "true" ]]; then
    restart_result=$(_restart_donna_ops_service)
  fi

  cat <<EOF
{
  "success": true,
  "updated": true,
  "before_commit": "$before_commit",
  "after_commit": "$after_commit",
  "update_message": $(echo "$update_message" | jq -Rs '.'),
  "restart": "$restart_result"
}
EOF
}

# 內部函式：重啟 donna-ops 服務
_restart_donna_ops_service() {
  # 方法 1: systemd 服務
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet donna-ops 2>/dev/null; then
      systemctl restart donna-ops 2>/dev/null && {
        echo "systemd"
        return 0
      }
    fi
  fi

  # 方法 2: PID 檔案
  local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local state_dir="${script_dir}/state"

  local restarted="false"
  for pid_file in "${state_dir}/periodic.pid" "${state_dir}/poller.pid"; do
    if [[ -f "$pid_file" ]]; then
      local pid
      pid=$(cat "$pid_file")
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        restarted="true"
      fi
    fi
  done

  if [[ "$restarted" == "true" ]]; then
    # 給一點時間讓進程結束
    sleep 2

    # 重新啟動 daemon
    if [[ -x "${script_dir}/donna-ops.sh" ]]; then
      nohup "${script_dir}/donna-ops.sh" daemon >> "${script_dir}/logs/donna-ops.log" 2>&1 &
      echo "pid"
      return 0
    fi
  fi

  echo "none"
}

# 內部函式：回報更新到 GitHub
_report_update_to_github() {
  local before_commit="$1"
  local after_commit="$2"
  local update_message="$3"

  # 檢查狀態回報是否可用
  if ! declare -f report_status_to_github >/dev/null 2>&1; then
    return 0
  fi

  if [[ "${STATUS_REPORT_ENABLED:-false}" != "true" ]]; then
    return 0
  fi

  local hostname
  hostname=$(hostname)
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')

  # 建立更新通知報告
  local report="## 🔄 ${hostname} - 已自動更新

**更新時間**: ${timestamp}

### 📦 版本變更
- **更新前**: \`${before_commit}\`
- **更新後**: \`${after_commit}\`
- **變更說明**: ${update_message}

---
<sub>🤖 自動更新 by Donna-Ops</sub>"

  # 回報到 GitHub
  if [[ -n "$STATUS_ISSUE_NUMBER" ]]; then
    gh issue comment "$STATUS_ISSUE_NUMBER" \
      --repo "$GITHUB_REPO" \
      --body "$report" \
      2>/dev/null || true
  fi
}

# 條件式自動更新（檢查間隔）
# 用法: auto_update_if_needed
auto_update_if_needed() {
  if [[ "$UPDATER_ENABLED" != "true" ]]; then
    return 0
  fi

  # 檢查是否到了更新時間
  local now
  now=$(date +%s)
  local interval_seconds=$((UPDATER_CHECK_INTERVAL * 60))

  if (( now - UPDATER_LAST_CHECK < interval_seconds )); then
    return 0  # 還在間隔內
  fi

  UPDATER_LAST_CHECK=$now

  # 檢查更新
  local check_result
  check_result=$(check_for_updates 2>/dev/null)

  local available
  available=$(echo "$check_result" | jq -r '.available // false' 2>/dev/null)

  if [[ "$available" == "true" ]]; then
    if declare -f log_info >/dev/null 2>&1; then
      log_info "[Updater] 發現新版本，開始更新..."
    fi

    perform_update
  fi
}

# 檢查是否應該更新（基於時間間隔）
# 用法: should_check_update
should_check_update() {
  if [[ "$UPDATER_ENABLED" != "true" ]]; then
    return 1
  fi

  local state_dir="${SCRIPT_DIR:-/opt/donna-ops}/state"
  local last_check_file="${state_dir}/last_update_check"

  mkdir -p "$state_dir" 2>/dev/null || true

  if [[ -f "$last_check_file" ]]; then
    local last_check
    last_check=$(cat "$last_check_file")
    local now
    now=$(date +%s)
    local interval_seconds=$((UPDATER_CHECK_INTERVAL * 60))

    if (( now - last_check < interval_seconds )); then
      return 1
    fi
  fi

  return 0
}

# 記錄檢查時間
mark_update_checked() {
  local state_dir="${SCRIPT_DIR:-/opt/donna-ops}/state"
  local last_check_file="${state_dir}/last_update_check"

  mkdir -p "$state_dir" 2>/dev/null || true
  date +%s > "$last_check_file"
}

# 取得目前版本資訊
get_version_info() {
  local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

  local version="unknown"
  local commit="unknown"
  local branch="unknown"
  local date="unknown"

  # 嘗試從 donna-ops.sh 取得版本
  if [[ -f "${script_dir}/donna-ops.sh" ]]; then
    version=$(grep -oP 'VERSION="\K[^"]+' "${script_dir}/donna-ops.sh" 2>/dev/null || echo "unknown")
  fi

  # 取得 Git 資訊
  if git -C "$script_dir" rev-parse --git-dir >/dev/null 2>&1; then
    commit=$(git -C "$script_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    branch=$(git -C "$script_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    date=$(git -C "$script_dir" log -1 --format="%ci" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
  fi

  cat <<EOF
{
  "version": "$version",
  "commit": "$commit",
  "branch": "$branch",
  "date": "$date"
}
EOF
}

# 設定自動重啟
updater_set_auto_restart() {
  local enabled="$1"
  case "${enabled,,}" in
    true|yes|1|on)  UPDATER_AUTO_RESTART="true" ;;
    false|no|0|off) UPDATER_AUTO_RESTART="false" ;;
  esac
}

# 設定目標分支
updater_set_branch() {
  UPDATER_BRANCH="$1"
}

# 設定檢查間隔
updater_set_interval() {
  UPDATER_CHECK_INTERVAL="$1"
}
