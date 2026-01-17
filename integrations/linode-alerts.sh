#!/usr/bin/env bash
###############################################
# integrations/linode-alerts.sh
# Linode Alert 整合
#   - fetch_active_alerts()     取得警報
#   - correlate_with_issues()   關聯 GitHub issues
#   - process_linode_alert()    處理單一警報
###############################################

if [[ -n "${INTEGRATION_LINODE_ALERTS_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
INTEGRATION_LINODE_ALERTS_SH_LOADED=1

# 全域變數
declare -g LINODE_ALERTS_LAST_CHECK=""
declare -g LINODE_ALERTS_CACHE=""

# 取得活躍警報
# 這是對 collectors/linode.sh 的封裝，加上額外處理
fetch_active_alerts() {
  local instance_id="${1:-}"

  # 呼叫 collector
  local alerts_json
  alerts_json=$(poll_linode_alerts "$instance_id" 2>/dev/null)

  if [[ -z "$alerts_json" ]]; then
    echo '{"error": "無法取得警報", "alerts": []}'
    return 1
  fi

  # 更新快取
  LINODE_ALERTS_CACHE="$alerts_json"
  LINODE_ALERTS_LAST_CHECK=$(date +%s)

  # 加入額外資訊
  local alert_count
  alert_count=$(echo "$alerts_json" | jq '.alert_count // 0')

  local processed_alerts="[]"
  while IFS= read -r alert; do
    [[ -z "$alert" || "$alert" == "null" ]] && continue

    # 解析警報類型
    local parsed_type
    parsed_type=$(parse_alert_type "$alert" 2>/dev/null)

    local normalized_type category
    normalized_type=$(echo "$parsed_type" | jq -r '.normalized_type // "unknown"')
    category=$(echo "$parsed_type" | jq -r '.category // "other"')

    # 加入解析資訊
    local enriched_alert
    enriched_alert=$(echo "$alert" | jq \
      --arg norm_type "$normalized_type" --arg cat "$category" \
      '. + {"normalized_type": $norm_type, "category": $cat}')

    processed_alerts=$(echo "$processed_alerts" | jq --argjson a "$enriched_alert" '. + [$a]')
  done < <(echo "$alerts_json" | jq -c '.alerts[]' 2>/dev/null)

  cat <<EOF
{
  "instance_id": $(echo "$alerts_json" | jq '.instance_id'),
  "alert_count": $alert_count,
  "fetched_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "alerts": $processed_alerts
}
EOF
}

# 關聯警報與 GitHub Issues
# 用法：correlate_with_issues "alerts_json"
correlate_with_issues() {
  local alerts_json="$1"

  if [[ -z "$GITHUB_REPO" ]]; then
    echo '{"error": "GITHUB_REPO not configured", "correlations": []}'
    return 1
  fi

  local correlations="[]"

  while IFS= read -r alert; do
    [[ -z "$alert" || "$alert" == "null" ]] && continue

    local alert_type normalized_type
    alert_type=$(echo "$alert" | jq -r '.type')
    normalized_type=$(echo "$alert" | jq -r '.normalized_type // .type')

    # 查找相關 Issue
    local issue_id="linode_${normalized_type}"
    local existing_issue
    existing_issue=$(find_issue_by_id "$issue_id" 2>/dev/null)

    local correlation
    if [[ -n "$existing_issue" ]]; then
      correlation=$(echo "$alert" | jq \
        --arg issue_id "$issue_id" --argjson issue_num "$existing_issue" \
        '. + {"issue_id": $issue_id, "github_issue": $issue_num, "has_issue": true}')
    else
      correlation=$(echo "$alert" | jq \
        --arg issue_id "$issue_id" \
        '. + {"issue_id": $issue_id, "github_issue": null, "has_issue": false}')
    fi

    correlations=$(echo "$correlations" | jq --argjson c "$correlation" '. + [$c]')
  done < <(echo "$alerts_json" | jq -c '.alerts[]' 2>/dev/null)

  echo "{\"correlations\": $correlations}"
}

# 處理單一 Linode 警報
# 用法：process_linode_alert "alert_json"
process_linode_alert() {
  local alert_json="$1"

  local alert_type severity message normalized_type
  alert_type=$(echo "$alert_json" | jq -r '.type')
  severity=$(echo "$alert_json" | jq -r '.severity // "minor"')
  message=$(echo "$alert_json" | jq -r '.message // ""')
  normalized_type=$(echo "$alert_json" | jq -r '.normalized_type // .type')

  # 產生 Issue ID
  local issue_id="linode_${normalized_type}"

  # 映射嚴重度
  local mapped_severity
  case "$severity" in
    critical) mapped_severity="critical" ;;
    major)    mapped_severity="high" ;;
    minor)    mapped_severity="low" ;;
    *)        mapped_severity="medium" ;;
  esac

  # 產生標題
  local title="Linode Alert: $alert_type"

  # 產生內容
  local body="## Linode Alert

**Type:** $alert_type
**Severity:** $severity
**Message:** $message

### Alert Details
\`\`\`json
$alert_json
\`\`\`

---
*Alert received at $(date '+%Y-%m-%d %H:%M:%S')*
"

  # 建立或更新 Issue
  create_or_update_issue "$issue_id" "$title" "$body" "$mapped_severity" "linode"
}

# 批次處理所有警報
# 用法：process_all_alerts "alerts_json"
process_all_alerts() {
  local alerts_json="$1"

  local processed=0
  local errors=0
  local results="[]"

  while IFS= read -r alert; do
    [[ -z "$alert" || "$alert" == "null" ]] && continue

    local result
    result=$(process_linode_alert "$alert" 2>&1)
    local code=$?

    if (( code == 0 )); then
      ((processed++))
    else
      ((errors++))
    fi

    results=$(echo "$results" | jq --argjson r "$result" '. + [$r]')
  done < <(echo "$alerts_json" | jq -c '.alerts[]' 2>/dev/null)

  cat <<EOF
{
  "processed": $processed,
  "errors": $errors,
  "results": $results
}
EOF
}

# 取得警報摘要
get_alert_summary() {
  local alerts_json="${1:-$LINODE_ALERTS_CACHE}"

  if [[ -z "$alerts_json" ]]; then
    echo '{"summary": "沒有警報資料"}'
    return 0
  fi

  local count critical major minor
  count=$(echo "$alerts_json" | jq '.alert_count // (.alerts | length)')
  critical=$(echo "$alerts_json" | jq '[.alerts[] | select(.severity == "critical")] | length')
  major=$(echo "$alerts_json" | jq '[.alerts[] | select(.severity == "major")] | length')
  minor=$(echo "$alerts_json" | jq '[.alerts[] | select(.severity == "minor")] | length')

  local by_type
  by_type=$(echo "$alerts_json" | jq '[.alerts[].normalized_type // .alerts[].type] | group_by(.) | map({type: .[0], count: length})')

  cat <<EOF
{
  "total_alerts": $count,
  "by_severity": {
    "critical": $critical,
    "major": $major,
    "minor": $minor
  },
  "by_type": $by_type,
  "last_check": "${LINODE_ALERTS_LAST_CHECK:-unknown}"
}
EOF
}

# 偵測新警報（與上次比較）
detect_new_alerts() {
  local current_alerts="$1"
  local previous_alerts="${2:-}"

  if [[ -z "$previous_alerts" ]]; then
    # 沒有先前的警報資料，所有都是新的
    echo "$current_alerts"
    return 0
  fi

  local new_alerts="[]"

  while IFS= read -r alert; do
    [[ -z "$alert" || "$alert" == "null" ]] && continue

    local alert_type message
    alert_type=$(echo "$alert" | jq -r '.type')
    message=$(echo "$alert" | jq -r '.message')

    # 檢查是否在先前的警報中
    local exists
    exists=$(echo "$previous_alerts" | jq --arg t "$alert_type" --arg m "$message" \
      '[.alerts[] | select(.type == $t and .message == $m)] | length')

    if (( exists == 0 )); then
      new_alerts=$(echo "$new_alerts" | jq --argjson a "$alert" '. + [$a]')
    fi
  done < <(echo "$current_alerts" | jq -c '.alerts[]' 2>/dev/null)

  local new_count
  new_count=$(echo "$new_alerts" | jq 'length')

  cat <<EOF
{
  "new_count": $new_count,
  "new_alerts": $new_alerts
}
EOF
}

# 警報狀態追蹤
# 用於追蹤哪些警報已處理
declare -gA PROCESSED_ALERTS=()

mark_alert_processed() {
  local alert_key="$1"
  PROCESSED_ALERTS["$alert_key"]=1
}

is_alert_processed() {
  local alert_key="$1"
  [[ -n "${PROCESSED_ALERTS[$alert_key]}" ]]
}

get_alert_key() {
  local alert_json="$1"
  local type message when
  type=$(echo "$alert_json" | jq -r '.type')
  message=$(echo "$alert_json" | jq -r '.message' | head -c 50)
  when=$(echo "$alert_json" | jq -r '.when // ""')
  echo "${type}_${when}_$(echo "$message" | md5sum | cut -c1-8)"
}

# 清除已處理警報記錄
clear_processed_alerts() {
  PROCESSED_ALERTS=()
}
