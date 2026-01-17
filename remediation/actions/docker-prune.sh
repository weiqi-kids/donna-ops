#!/usr/bin/env bash
###############################################
# remediation/actions/docker-prune.sh
# Description: 清理未使用的 Docker 資源
# Risk Level: low
# Auto-executable: true
###############################################

# 驗證動作
action_validate() {
  # 檢查 Docker 是否可用
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker 未安裝"
    return 1
  fi

  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon 未執行或無權限"
    return 1
  fi

  return 0
}

# 執行動作
action_execute() {
  local target="${1:-all}"
  local freed_space=0

  echo "開始 Docker 清理..."

  case "$target" in
    containers)
      echo "清理已停止的容器..."
      docker container prune -f 2>&1
      ;;
    images)
      echo "清理未使用的映像..."
      docker image prune -f 2>&1
      ;;
    volumes)
      echo "清理未使用的 volumes..."
      docker volume prune -f 2>&1
      ;;
    networks)
      echo "清理未使用的網路..."
      docker network prune -f 2>&1
      ;;
    builder)
      echo "清理建構快取..."
      docker builder prune -f 2>&1 || true
      ;;
    all|*)
      # 完整清理

      # 1. 清理已停止的容器
      echo "1. 清理已停止的容器..."
      local containers_before
      containers_before=$(docker ps -aq --filter "status=exited" 2>/dev/null | wc -l | tr -d ' ')
      docker container prune -f 2>&1
      echo "   已移除 $containers_before 個容器"

      # 2. 清理未使用的映像（不包含 tag）
      echo "2. 清理 dangling 映像..."
      local images_before
      images_before=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l | tr -d ' ')
      docker image prune -f 2>&1
      echo "   已移除 $images_before 個映像"

      # 3. 清理未使用的 volumes
      echo "3. 清理未使用的 volumes..."
      docker volume prune -f 2>&1

      # 4. 清理未使用的網路
      echo "4. 清理未使用的網路..."
      docker network prune -f 2>&1

      # 5. 清理建構快取
      echo "5. 清理建構快取..."
      docker builder prune -f 2>&1 || true

      # 6. 選擇性清理超過 30 天的映像
      echo "6. 清理超過 30 天未使用的映像..."
      docker image prune -a -f --filter "until=720h" 2>&1 || true
      ;;
  esac

  # 顯示清理後的磁碟使用
  echo ""
  echo "Docker 磁碟使用情況："
  docker system df 2>&1

  echo ""
  echo "Docker 清理完成"
  return 0
}

# 驗證結果
action_verify() {
  # 檢查 Docker 是否正常運作
  if ! docker info >/dev/null 2>&1; then
    echo "錯誤：Docker 無法正常運作"
    return 1
  fi

  # 檢查正在運行的容器
  local running
  running=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
  echo "目前運行中的容器：$running"

  # 顯示磁碟使用
  local disk_usage
  disk_usage=$(docker system df --format '{{.Type}}: {{.Size}} (可回收: {{.Reclaimable}})' 2>/dev/null)
  echo "磁碟使用："
  echo "$disk_usage"

  return 0
}
