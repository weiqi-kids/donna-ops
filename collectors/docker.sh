#!/usr/bin/env bash
###############################################
# collectors/docker.sh
# Docker 容器狀態收集器
#   - collect_docker_stats()        收集容器資源使用
#   - collect_docker_health()       收集容器健康狀態
#   - collect_unhealthy_containers() 收集不健康的容器
#   - collect_docker_summary()      Docker 整體摘要
###############################################

if [[ -n "${COLLECTOR_DOCKER_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
COLLECTOR_DOCKER_SH_LOADED=1

# 檢查 Docker 是否可用
docker_available() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# 收集容器資源使用
# 回傳 JSON 陣列
collect_docker_stats() {
  if ! docker_available; then
    echo '{"error": "docker not available", "containers": []}'
    return 1
  fi

  local stats_output
  stats_output=$(docker stats --no-stream --format '{{.Container}}\t{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}' 2>/dev/null)

  if [[ -z "$stats_output" ]]; then
    echo '{"containers": []}'
    return 0
  fi

  local containers="[]"
  while IFS=$'\t' read -r id name cpu mem_usage mem_perc net_io block_io; do
    # 清理百分比符號
    cpu="${cpu%\%}"
    mem_perc="${mem_perc%\%}"

    # 解析記憶體使用（格式：123MiB / 456MiB）
    local mem_used mem_limit
    mem_used=$(echo "$mem_usage" | awk -F'/' '{print $1}' | tr -d ' ')
    mem_limit=$(echo "$mem_usage" | awk -F'/' '{print $2}' | tr -d ' ')

    containers=$(echo "$containers" | jq \
      --arg id "$id" --arg name "$name" \
      --arg cpu "$cpu" --arg mem_perc "$mem_perc" \
      --arg mem_used "$mem_used" --arg mem_limit "$mem_limit" \
      --arg net "$net_io" --arg block "$block_io" \
      '. + [{
        "id": $id,
        "name": $name,
        "cpu_percent": ($cpu | tonumber // 0),
        "mem_percent": ($mem_perc | tonumber // 0),
        "mem_used": $mem_used,
        "mem_limit": $mem_limit,
        "net_io": $net,
        "block_io": $block
      }]')
  done <<< "$stats_output"

  echo "{\"containers\": $containers}"
}

# 收集容器健康狀態
# 回傳 JSON 陣列
collect_docker_health() {
  if ! docker_available; then
    echo '{"error": "docker not available", "containers": []}'
    return 1
  fi

  local containers="[]"
  local format='{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.State}}\t{{if .Health}}{{.Health.Status}}{{else}}none{{end}}'

  while IFS=$'\t' read -r id name status state health; do
    [[ -z "$id" ]] && continue

    # 計算 uptime（從 status 解析）
    local uptime=""
    if [[ "$status" =~ Up\ (.+) ]]; then
      uptime="${BASH_REMATCH[1]}"
    fi

    containers=$(echo "$containers" | jq \
      --arg id "$id" --arg name "$name" \
      --arg status "$status" --arg state "$state" \
      --arg health "$health" --arg uptime "$uptime" \
      '. + [{
        "id": $id,
        "name": $name,
        "status": $status,
        "state": $state,
        "health": $health,
        "uptime": $uptime
      }]')
  done < <(docker ps -a --format "$format" 2>/dev/null)

  echo "{\"containers\": $containers}"
}

# 收集不健康的容器
# 回傳有問題的容器清單
collect_unhealthy_containers() {
  if ! docker_available; then
    echo '{"error": "docker not available", "unhealthy": []}'
    return 1
  fi

  local unhealthy="[]"

  # 狀態不是 running
  while IFS=$'\t' read -r id name state; do
    [[ -z "$id" ]] && continue
    if [[ "$state" != "running" ]]; then
      unhealthy=$(echo "$unhealthy" | jq \
        --arg id "$id" --arg name "$name" --arg state "$state" \
        --arg reason "not_running" \
        '. + [{"id": $id, "name": $name, "state": $state, "reason": $reason}]')
    fi
  done < <(docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.State}}' 2>/dev/null)

  # 健康檢查失敗
  while IFS=$'\t' read -r id name health; do
    [[ -z "$id" ]] && continue
    if [[ "$health" == "unhealthy" ]]; then
      # 檢查是否已在清單中
      local exists
      exists=$(echo "$unhealthy" | jq --arg id "$id" '[.[] | select(.id == $id)] | length')
      if [[ "$exists" == "0" ]]; then
        unhealthy=$(echo "$unhealthy" | jq \
          --arg id "$id" --arg name "$name" --arg health "$health" \
          --arg reason "health_check_failed" \
          '. + [{"id": $id, "name": $name, "state": "running", "health": $health, "reason": $reason}]')
      fi
    fi
  done < <(docker ps --format '{{.ID}}\t{{.Names}}\t{{if .Health}}{{.Health.Status}}{{else}}none{{end}}' 2>/dev/null)

  # 高資源使用
  local stats_json
  stats_json=$(collect_docker_stats)
  while IFS= read -r container; do
    local id name cpu_percent mem_percent
    id=$(echo "$container" | jq -r '.id')
    name=$(echo "$container" | jq -r '.name')
    cpu_percent=$(echo "$container" | jq -r '.cpu_percent')
    mem_percent=$(echo "$container" | jq -r '.mem_percent')

    # CPU > 90% 或 Memory > 90%
    if (( $(echo "$cpu_percent > 90" | bc -l 2>/dev/null || echo 0) )) || \
       (( $(echo "$mem_percent > 90" | bc -l 2>/dev/null || echo 0) )); then
      local exists
      exists=$(echo "$unhealthy" | jq --arg id "$id" '[.[] | select(.id == $id)] | length')
      if [[ "$exists" == "0" ]]; then
        unhealthy=$(echo "$unhealthy" | jq \
          --arg id "$id" --arg name "$name" \
          --arg cpu "$cpu_percent" --arg mem "$mem_percent" \
          --arg reason "high_resource_usage" \
          '. + [{"id": $id, "name": $name, "cpu_percent": ($cpu|tonumber), "mem_percent": ($mem|tonumber), "reason": $reason}]')
      fi
    fi
  done < <(echo "$stats_json" | jq -c '.containers[]' 2>/dev/null)

  echo "{\"unhealthy\": $unhealthy}"
}

# Docker 整體摘要
collect_docker_summary() {
  if ! docker_available; then
    echo '{"available": false}'
    return 1
  fi

  local total running paused stopped
  total=$(docker ps -a -q 2>/dev/null | wc -l | tr -d ' ')
  running=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
  paused=$(docker ps -q -f status=paused 2>/dev/null | wc -l | tr -d ' ')
  stopped=$((total - running - paused))

  # 映像數量
  local images
  images=$(docker images -q 2>/dev/null | wc -l | tr -d ' ')

  # 磁碟使用
  local disk_usage
  disk_usage=$(docker system df --format '{{.Type}}\t{{.Size}}\t{{.Reclaimable}}' 2>/dev/null)

  local images_size containers_size volumes_size build_cache_size
  images_size=$(echo "$disk_usage" | grep "Images" | awk '{print $2}')
  containers_size=$(echo "$disk_usage" | grep "Containers" | awk '{print $2}')
  volumes_size=$(echo "$disk_usage" | grep "Volumes" | awk '{print $2}' | head -1)
  build_cache_size=$(echo "$disk_usage" | grep "Build" | awk '{print $2}')

  # 不健康容器數量
  local unhealthy_json unhealthy_count
  unhealthy_json=$(collect_unhealthy_containers)
  unhealthy_count=$(echo "$unhealthy_json" | jq '.unhealthy | length')

  cat <<EOF
{
  "available": true,
  "containers": {
    "total": $total,
    "running": $running,
    "paused": $paused,
    "stopped": $stopped,
    "unhealthy": $unhealthy_count
  },
  "images": $images,
  "disk_usage": {
    "images": "${images_size:-0B}",
    "containers": "${containers_size:-0B}",
    "volumes": "${volumes_size:-0B}",
    "build_cache": "${build_cache_size:-0B}"
  }
}
EOF
}

# 取得容器的最近日誌
# 用法：collect_container_logs "container_name" [lines]
collect_container_logs() {
  local container="$1"
  local lines="${2:-50}"

  if ! docker_available; then
    echo '{"error": "docker not available"}'
    return 1
  fi

  local logs
  logs=$(docker logs --tail "$lines" "$container" 2>&1)

  # 轉換為 JSON 格式
  local escaped_logs
  escaped_logs=$(echo "$logs" | jq -Rs '.')

  echo "{\"container\": \"$container\", \"lines\": $lines, \"logs\": $escaped_logs}"
}

# 檢查特定容器是否在執行
docker_container_running() {
  local container="$1"
  docker ps -q -f name="^${container}$" 2>/dev/null | grep -q .
}

# 取得容器的完整資訊
collect_container_info() {
  local container="$1"

  if ! docker_available; then
    echo '{"error": "docker not available"}'
    return 1
  fi

  docker inspect "$container" 2>/dev/null | jq '.[0]' || echo '{"error": "container not found"}'
}
