#!/usr/bin/env bash
###############################################
# integrations/github-issues.sh
# GitHub Issue 管理
#   - create_issue()        建立 issue
#   - update_issue()        更新 issue (加註解)
#   - close_issue()         關閉 issue
#   - find_existing_issue() 查找重複 issue
###############################################

if [[ -n "${INTEGRATION_GITHUB_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
INTEGRATION_GITHUB_SH_LOADED=1

# 設定
declare -g GITHUB_REPO=""
declare -g GITHUB_DRY_RUN="false"

# 標籤定義
declare -gA SEVERITY_LABELS=(
  [critical]="severity/critical"
  [high]="severity/high"
  [medium]="severity/medium"
  [low]="severity/low"
)

declare -gA TYPE_LABELS=(
  [threshold]="type/threshold"
  [docker]="type/docker"
  [linode]="type/linode"
  [system]="type/system"
)

# 初始化 GitHub 設定
github_init() {
  GITHUB_REPO="${1:-$GITHUB_REPO}"

  if [[ -z "$GITHUB_REPO" ]]; then
    echo "ERROR: GITHUB_REPO 未設定" >&2
    return 1
  fi

  # 檢查 gh CLI 是否可用
  if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI 未安裝" >&2
    return 1
  fi

  # 檢查認證
  if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh CLI 未認證" >&2
    return 1
  fi

  return 0
}

# 建立 Issue
# 用法：create_issue "title" "body" "severity" "type" [labels...]
create_issue() {
  local title="$1"
  local body="$2"
  local severity="${3:-medium}"
  local issue_type="${4:-system}"
  shift 4 || true
  local extra_labels=("$@")

  if [[ -z "$GITHUB_REPO" ]]; then
    echo '{"error": "GITHUB_REPO not configured"}'
    return 1
  fi

  # 組合標籤
  local labels=("donna-ops" "auto-generated")
  [[ -n "${SEVERITY_LABELS[$severity]}" ]] && labels+=("${SEVERITY_LABELS[$severity]}")
  [[ -n "${TYPE_LABELS[$issue_type]}" ]] && labels+=("${TYPE_LABELS[$issue_type]}")
  labels+=("${extra_labels[@]}")

  local labels_str
  labels_str=$(IFS=','; echo "${labels[*]}")

  if [[ "$GITHUB_DRY_RUN" == "true" ]]; then
    cat <<EOF
{
  "dry_run": true,
  "action": "create_issue",
  "title": $(echo "$title" | jq -Rs '.'),
  "labels": $(echo "${labels[@]}" | jq -R 'split(" ")'),
  "body_preview": $(echo "$body" | head -c 200 | jq -Rs '.')
}
EOF
    return 0
  fi

  # 建立 Issue
  local result
  result=$(gh issue create \
    --repo "$GITHUB_REPO" \
    --title "$title" \
    --body "$body" \
    --label "$labels_str" \
    2>&1)

  local exit_code=$?

  if (( exit_code != 0 )); then
    echo "{\"error\": \"建立 Issue 失敗\", \"details\": $(echo "$result" | jq -Rs '.')}"
    return 1
  fi

  # 解析 Issue URL 取得編號
  local issue_url issue_number
  issue_url="$result"
  issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$')

  cat <<EOF
{
  "success": true,
  "issue_number": $issue_number,
  "url": "$issue_url",
  "title": $(echo "$title" | jq -Rs '.'),
  "labels": $(echo "${labels[@]}" | jq -R 'split(" ")')
}
EOF
}

# 更新 Issue（加註解）
# 用法：update_issue "issue_number" "comment"
update_issue() {
  local issue_number="$1"
  local comment="$2"

  if [[ -z "$GITHUB_REPO" ]]; then
    echo '{"error": "GITHUB_REPO not configured"}'
    return 1
  fi

  if [[ -z "$issue_number" || -z "$comment" ]]; then
    echo '{"error": "issue_number and comment are required"}'
    return 1
  fi

  if [[ "$GITHUB_DRY_RUN" == "true" ]]; then
    cat <<EOF
{
  "dry_run": true,
  "action": "update_issue",
  "issue_number": $issue_number,
  "comment_preview": $(echo "$comment" | head -c 200 | jq -Rs '.')
}
EOF
    return 0
  fi

  local result
  result=$(gh issue comment "$issue_number" \
    --repo "$GITHUB_REPO" \
    --body "$comment" \
    2>&1)

  local exit_code=$?

  if (( exit_code != 0 )); then
    echo "{\"error\": \"更新 Issue 失敗\", \"details\": $(echo "$result" | jq -Rs '.')}"
    return 1
  fi

  cat <<EOF
{
  "success": true,
  "issue_number": $issue_number,
  "action": "comment_added"
}
EOF
}

# 關閉 Issue
# 用法：close_issue "issue_number" [comment]
close_issue() {
  local issue_number="$1"
  local comment="${2:-}"

  if [[ -z "$GITHUB_REPO" ]]; then
    echo '{"error": "GITHUB_REPO not configured"}'
    return 1
  fi

  if [[ "$GITHUB_DRY_RUN" == "true" ]]; then
    cat <<EOF
{
  "dry_run": true,
  "action": "close_issue",
  "issue_number": $issue_number
}
EOF
    return 0
  fi

  # 如果有註解，先加註解
  if [[ -n "$comment" ]]; then
    gh issue comment "$issue_number" \
      --repo "$GITHUB_REPO" \
      --body "$comment" \
      2>/dev/null || true
  fi

  # 關閉 Issue
  local result
  result=$(gh issue close "$issue_number" \
    --repo "$GITHUB_REPO" \
    --reason "completed" \
    2>&1)

  local exit_code=$?

  if (( exit_code != 0 )); then
    echo "{\"error\": \"關閉 Issue 失敗\", \"details\": $(echo "$result" | jq -Rs '.')}"
    return 1
  fi

  cat <<EOF
{
  "success": true,
  "issue_number": $issue_number,
  "action": "closed"
}
EOF
}

# 查找現有的相似 Issue
# 用法：find_existing_issue "search_query"
find_existing_issue() {
  local query="$1"
  local issue_type="${2:-}"

  if [[ -z "$GITHUB_REPO" ]]; then
    echo '{"error": "GITHUB_REPO not configured"}'
    return 1
  fi

  # 建構搜尋查詢
  local search_query="repo:${GITHUB_REPO} is:issue is:open label:donna-ops"
  if [[ -n "$query" ]]; then
    search_query="$search_query $query in:title"
  fi
  if [[ -n "$issue_type" && -n "${TYPE_LABELS[$issue_type]}" ]]; then
    search_query="$search_query label:${TYPE_LABELS[$issue_type]}"
  fi

  # 搜尋
  local results
  results=$(gh issue list \
    --repo "$GITHUB_REPO" \
    --state open \
    --label "donna-ops" \
    --search "$query" \
    --json number,title,labels,createdAt \
    --limit 5 \
    2>/dev/null)

  if [[ -z "$results" || "$results" == "[]" ]]; then
    echo '{"found": false, "issues": []}'
    return 0
  fi

  cat <<EOF
{
  "found": true,
  "count": $(echo "$results" | jq 'length'),
  "issues": $results
}
EOF
}

# 根據 Issue ID 查找
find_issue_by_id() {
  local issue_id="$1"

  # 搜尋 title 中包含 issue_id 的 Issue
  local results
  results=$(gh issue list \
    --repo "$GITHUB_REPO" \
    --state open \
    --label "donna-ops" \
    --search "[$issue_id]" \
    --json number,title,state \
    --limit 1 \
    2>/dev/null)

  if [[ -z "$results" || "$results" == "[]" ]]; then
    echo ""
    return 1
  fi

  echo "$results" | jq -r '.[0].number'
}

# 建立或更新 Issue（智慧處理）
# 用法：create_or_update_issue "issue_id" "title" "body" "severity" "type"
create_or_update_issue() {
  local issue_id="$1"
  local title="$2"
  local body="$3"
  local severity="${4:-medium}"
  local issue_type="${5:-system}"

  # 在標題中加入 issue_id 以便追蹤
  local full_title="[${issue_id}] ${title}"

  # 查找現有 Issue
  local existing_number
  existing_number=$(find_issue_by_id "$issue_id")

  if [[ -n "$existing_number" ]]; then
    # 更新現有 Issue
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local update_comment="### 更新 ($timestamp)

$body"
    update_issue "$existing_number" "$update_comment"
  else
    # 建立新 Issue
    create_issue "$full_title" "$body" "$severity" "$issue_type"
  fi
}

# 格式化 Issue 內容
format_issue_body() {
  local alert_summary="$1"
  local analysis="${2:-}"
  local system_info="${3:-}"

  local hostname
  hostname=$(hostname)
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  local body="## Alert Summary

**Host:** $hostname
**Time:** $timestamp

### Issues Detected
"

  # 加入問題清單
  local issues
  issues=$(echo "$alert_summary" | jq -r '.issues[]? | "- **\(.type)**: \(.metric // .container // .alert_type // "unknown") (\(.severity))"' 2>/dev/null)
  body+="$issues"
  body+="

### Details
\`\`\`json
$alert_summary
\`\`\`
"

  # 加入分析結果（如果有）
  if [[ -n "$analysis" && "$analysis" != "null" ]]; then
    local diagnosis
    diagnosis=$(echo "$analysis" | jq -r '.diagnosis // "N/A"')
    local recommendations
    recommendations=$(echo "$analysis" | jq -r '.recommendations[]? | "- \(.action): \(.description)"' 2>/dev/null)

    body+="
### AI Analysis

**Diagnosis:** $diagnosis

**Recommendations:**
$recommendations
"
  fi

  # 加入系統資訊（如果有）
  if [[ -n "$system_info" && "$system_info" != "null" ]]; then
    body+="
### System Info
\`\`\`json
$system_info
\`\`\`
"
  fi

  body+="
---
*This issue was automatically created by donna-ops*
"

  echo "$body"
}

# 設定 dry-run 模式
github_set_dry_run() {
  local enabled="$1"
  case "${enabled,,}" in
    true|yes|1|on)  GITHUB_DRY_RUN="true" ;;
    false|no|0|off) GITHUB_DRY_RUN="false" ;;
  esac
}
