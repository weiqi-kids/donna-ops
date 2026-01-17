#!/usr/bin/env bash
###############################################
# collectors/linode.sh
# Linode Alert API 收集器
#   - poll_linode_alerts()     輪詢 Linode 警報
#   - parse_alert_type()       解析警報類型
#   - acknowledge_alert()      確認警報
#   - get_linode_status()      取得 Linode 狀態
###############################################

if [[ -n "${COLLECTOR_LINODE_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
COLLECTOR_LINODE_SH_LOADED=1

# Linode API 設定
declare -g LINODE_API_BASE="https://api.linode.com/v4"
declare -g LINODE_API_TOKEN=""
declare -g LINODE_INSTANCE_ID=""

# 初始化 Linode 設定
linode_init() {
  LINODE_API_TOKEN="${1:-$LINODE_API_TOKEN}"
  LINODE_INSTANCE_ID="${2:-$LINODE_INSTANCE_ID}"

  if [[ -z "$LINODE_API_TOKEN" ]]; then
    echo "ERROR: LINODE_API_TOKEN 未設定" >&2
    return 1
  fi

  return 0
}

# 內部函式：呼叫 Linode API
_linode_api() {
  local method="${1:-GET}"
  local endpoint="$2"
  local data="${3:-}"

  if [[ -z "$LINODE_API_TOKEN" ]]; then
    echo '{"error": "LINODE_API_TOKEN not configured"}'
    return 1
  fi

  local url="${LINODE_API_BASE}${endpoint}"
  local response

  if [[ "$method" == "GET" ]]; then
    response=$(curl -s -H "Authorization: Bearer $LINODE_API_TOKEN" \
      -H "Content-Type: application/json" \
      "$url" 2>&1)
  else
    response=$(curl -s -X "$method" \
      -H "Authorization: Bearer $LINODE_API_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$data" \
      "$url" 2>&1)
  fi

  echo "$response"
}

# 輪詢 Linode 警報
# 回傳活躍的警報清單
poll_linode_alerts() {
  local instance_id="${1:-$LINODE_INSTANCE_ID}"

  if [[ -z "$instance_id" ]]; then
    echo '{"error": "instance_id not specified", "alerts": []}'
    return 1
  fi

  # 取得 Linode 實例的通知/事件
  # Linode API 使用 /account/notifications 和 /account/events
  local notifications
  notifications=$(_linode_api GET "/account/notifications")

  if echo "$notifications" | jq -e '.errors' >/dev/null 2>&1; then
    echo "{\"error\": $(echo "$notifications" | jq '.errors'), \"alerts\": []}"
    return 1
  fi

  # 過濾與此 instance 相關的通知
  local alerts="[]"
  local alert_count=0

  while IFS= read -r notification; do
    [[ -z "$notification" || "$notification" == "null" ]] && continue

    local entity_id entity_type severity type label message when
    entity_id=$(echo "$notification" | jq -r '.entity.id // ""')
    entity_type=$(echo "$notification" | jq -r '.entity.type // ""')
    severity=$(echo "$notification" | jq -r '.severity // "minor"')
    type=$(echo "$notification" | jq -r '.type // ""')
    label=$(echo "$notification" | jq -r '.label // ""')
    message=$(echo "$notification" | jq -r '.message // ""')
    when=$(echo "$notification" | jq -r '.when // ""')

    # 只處理與此 instance 相關或系統級的通知
    if [[ "$entity_type" == "linode" && "$entity_id" != "$instance_id" && -n "$entity_id" ]]; then
      continue
    fi

    alerts=$(echo "$alerts" | jq \
      --arg type "$type" --arg severity "$severity" \
      --arg label "$label" --arg msg "$message" \
      --arg when "$when" --arg entity_id "$entity_id" \
      '. + [{
        "type": $type,
        "severity": $severity,
        "label": $label,
        "message": $msg,
        "when": $when,
        "entity_id": $entity_id
      }]')
    ((alert_count++))
  done < <(echo "$notifications" | jq -c '.data[]' 2>/dev/null)

  # 也檢查最近的事件
  local events
  events=$(_linode_api GET "/account/events?page_size=25")

  while IFS= read -r event; do
    [[ -z "$event" || "$event" == "null" ]] && continue

    local action status entity_id entity_type created
    action=$(echo "$event" | jq -r '.action // ""')
    status=$(echo "$event" | jq -r '.status // ""')
    entity_id=$(echo "$event" | jq -r '.entity.id // ""')
    entity_type=$(echo "$event" | jq -r '.entity.type // ""')
    created=$(echo "$event" | jq -r '.created // ""')

    # 只處理失敗或警告事件
    if [[ "$status" != "failed" && "$status" != "notification" ]]; then
      continue
    fi

    # 只處理與此 instance 相關的事件
    if [[ "$entity_type" == "linode" && "$entity_id" != "$instance_id" && -n "$entity_id" ]]; then
      continue
    fi

    alerts=$(echo "$alerts" | jq \
      --arg action "$action" --arg status "$status" \
      --arg created "$created" --arg entity_id "$entity_id" \
      '. + [{
        "type": ("event_" + $action),
        "severity": (if $status == "failed" then "major" else "minor" end),
        "label": $action,
        "message": ("Event: " + $action + " - " + $status),
        "when": $created,
        "entity_id": $entity_id
      }]')
    ((alert_count++))
  done < <(echo "$events" | jq -c '.data[]' 2>/dev/null)

  cat <<EOF
{
  "instance_id": "$instance_id",
  "alert_count": $alert_count,
  "alerts": $alerts
}
EOF
}

# 解析警報類型
# 用法：parse_alert_type "alert_json"
# 回傳標準化的警報類型
parse_alert_type() {
  local alert_json="$1"

  local type label message
  type=$(echo "$alert_json" | jq -r '.type // ""')
  label=$(echo "$alert_json" | jq -r '.label // ""')
  message=$(echo "$alert_json" | jq -r '.message // ""')

  # 根據 Linode 警報類型映射到內部類型
  local normalized_type="unknown"
  local category="other"

  case "$type" in
    cpu_usage|outage_cpu)
      normalized_type="cpu_high"
      category="resource"
      ;;
    io_usage)
      normalized_type="disk_io_high"
      category="resource"
      ;;
    network_usage|transfer_quota)
      normalized_type="network_high"
      category="network"
      ;;
    disk_io)
      normalized_type="disk_io_high"
      category="resource"
      ;;
    maintenance)
      normalized_type="maintenance"
      category="scheduled"
      ;;
    migration_*)
      normalized_type="migration"
      category="scheduled"
      ;;
    event_linode_boot|event_linode_reboot)
      normalized_type="reboot"
      category="system"
      ;;
    event_linode_shutdown)
      normalized_type="shutdown"
      category="system"
      ;;
    event_disk_*)
      normalized_type="disk_event"
      category="resource"
      ;;
    *)
      # 嘗試從 message 推斷
      if echo "$message" | grep -qi "cpu"; then
        normalized_type="cpu_high"
        category="resource"
      elif echo "$message" | grep -qi "memory\|ram"; then
        normalized_type="memory_high"
        category="resource"
      elif echo "$message" | grep -qi "disk\|storage"; then
        normalized_type="disk_high"
        category="resource"
      elif echo "$message" | grep -qi "network\|traffic"; then
        normalized_type="network_high"
        category="network"
      fi
      ;;
  esac

  cat <<EOF
{
  "original_type": "$type",
  "normalized_type": "$normalized_type",
  "category": "$category",
  "label": "$label"
}
EOF
}

# 取得 Linode 狀態
get_linode_status() {
  local instance_id="${1:-$LINODE_INSTANCE_ID}"

  if [[ -z "$instance_id" ]]; then
    echo '{"error": "instance_id not specified"}'
    return 1
  fi

  local response
  response=$(_linode_api GET "/linode/instances/${instance_id}")

  if echo "$response" | jq -e '.errors' >/dev/null 2>&1; then
    echo "{\"error\": $(echo "$response" | jq '.errors')}"
    return 1
  fi

  # 提取關鍵資訊
  local status label region type specs
  status=$(echo "$response" | jq -r '.status')
  label=$(echo "$response" | jq -r '.label')
  region=$(echo "$response" | jq -r '.region')
  type=$(echo "$response" | jq -r '.type')
  specs=$(echo "$response" | jq '{vcpus: .specs.vcpus, memory: .specs.memory, disk: .specs.disk, transfer: .specs.transfer}')

  cat <<EOF
{
  "id": "$instance_id",
  "status": "$status",
  "label": "$label",
  "region": "$region",
  "type": "$type",
  "specs": $specs
}
EOF
}

# 取得 Linode 統計資料
# 用法：get_linode_stats [instance_id]
get_linode_stats() {
  local instance_id="${1:-$LINODE_INSTANCE_ID}"

  if [[ -z "$instance_id" ]]; then
    echo '{"error": "instance_id not specified"}'
    return 1
  fi

  local response
  response=$(_linode_api GET "/linode/instances/${instance_id}/stats")

  if echo "$response" | jq -e '.errors' >/dev/null 2>&1; then
    echo "{\"error\": $(echo "$response" | jq '.errors')}"
    return 1
  fi

  # 提取最新的統計資料
  local cpu_data io_data netv4_data netv6_data
  cpu_data=$(echo "$response" | jq '.data.cpu | last // [0, 0]')
  io_data=$(echo "$response" | jq '.data.io.io | last // [0, 0]')
  netv4_data=$(echo "$response" | jq '{in: (.data.netv4.in | last // [0, 0]), out: (.data.netv4.out | last // [0, 0])}')

  cat <<EOF
{
  "instance_id": "$instance_id",
  "cpu": {
    "timestamp": $(echo "$cpu_data" | jq '.[0]'),
    "usage": $(echo "$cpu_data" | jq '.[1]')
  },
  "io": {
    "timestamp": $(echo "$io_data" | jq '.[0]'),
    "rate": $(echo "$io_data" | jq '.[1]')
  },
  "network_v4": $netv4_data
}
EOF
}

# 檢查是否有活躍警報
has_active_alerts() {
  local alerts_json
  alerts_json=$(poll_linode_alerts)
  local count
  count=$(echo "$alerts_json" | jq '.alert_count // 0')
  (( count > 0 ))
}

# 取得警報嚴重度
# 回傳：critical, major, minor, none
get_alert_severity() {
  local alerts_json
  alerts_json=$(poll_linode_alerts)

  local severities
  severities=$(echo "$alerts_json" | jq -r '.alerts[].severity' 2>/dev/null)

  if echo "$severities" | grep -q "critical"; then
    echo "critical"
  elif echo "$severities" | grep -q "major"; then
    echo "major"
  elif echo "$severities" | grep -q "minor"; then
    echo "minor"
  else
    echo "none"
  fi
}
