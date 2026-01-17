#!/usr/bin/env bash
###############################################
# remediation/actions/restart-service.sh
# Description: 重啟服務（Docker 容器或 systemd 服務）
# Risk Level: medium
# Auto-executable: false
###############################################

# 驗證動作
action_validate() {
  local target="$1"

  if [[ -z "$target" ]]; then
    echo "必須指定要重啟的服務名稱"
    return 1
  fi

  # 檢查是否為 Docker 容器
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${target}$"; then
      echo "目標是 Docker 容器: $target"
      return 0
    fi
  fi

  # 檢查是否為 systemd 服務
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${target}"; then
      echo "目標是 systemd 服務: $target"
      return 0
    fi
    if systemctl list-units --type=service 2>/dev/null | grep -q "${target}"; then
      echo "目標是 systemd 服務: $target"
      return 0
    fi
  fi

  echo "找不到服務或容器: $target"
  return 1
}

# 執行動作
action_execute() {
  local target="$1"
  local force="${2:-false}"

  echo "準備重啟服務: $target"

  # 判斷是 Docker 容器還是 systemd 服務
  local service_type=""

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${target}$"; then
      service_type="docker"
    fi
  fi

  if [[ -z "$service_type" ]] && command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${target}\|${target}.service"; then
      service_type="systemd"
    fi
  fi

  case "$service_type" in
    docker)
      echo "重啟 Docker 容器: $target"

      # 檢查容器狀態
      local state
      state=$(docker inspect --format '{{.State.Status}}' "$target" 2>/dev/null)

      if [[ "$state" == "running" ]]; then
        echo "停止容器..."
        docker stop "$target" 2>&1
        sleep 2
      fi

      echo "啟動容器..."
      docker start "$target" 2>&1

      # 等待容器啟動
      local wait_count=0
      while (( wait_count < 30 )); do
        state=$(docker inspect --format '{{.State.Status}}' "$target" 2>/dev/null)
        if [[ "$state" == "running" ]]; then
          break
        fi
        sleep 1
        ((wait_count++))
      done

      echo "容器狀態: $state"
      ;;

    systemd)
      local service_name="$target"
      [[ "$service_name" != *.service ]] && service_name="${target}.service"

      echo "重啟 systemd 服務: $service_name"

      if [[ "$force" == "true" ]]; then
        echo "強制重啟..."
        sudo systemctl kill "$service_name" 2>&1 || true
        sleep 2
      fi

      sudo systemctl restart "$service_name" 2>&1
      local restart_code=$?

      if (( restart_code != 0 )); then
        echo "重啟失敗，嘗試 start..."
        sudo systemctl start "$service_name" 2>&1
      fi

      # 等待服務啟動
      sleep 3
      systemctl status "$service_name" --no-pager 2>&1 | head -20
      ;;

    *)
      echo "無法識別服務類型: $target"
      return 1
      ;;
  esac

  echo "服務重啟完成: $target"
  return 0
}

# 驗證結果
action_verify() {
  local target="$1"

  # 判斷服務類型並檢查狀態
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${target}$"; then
      local state health
      state=$(docker inspect --format '{{.State.Status}}' "$target" 2>/dev/null)
      health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$target" 2>/dev/null)

      echo "容器狀態: $state"
      echo "健康狀態: $health"

      if [[ "$state" == "running" ]]; then
        if [[ "$health" == "unhealthy" ]]; then
          echo "警告: 容器運行但健康檢查失敗"
          return 1
        fi
        return 0
      else
        echo "錯誤: 容器未運行"
        return 1
      fi
    fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    local service_name="$target"
    [[ "$service_name" != *.service ]] && service_name="${target}.service"

    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
      echo "服務狀態: active"
      return 0
    else
      local status
      status=$(systemctl is-active "$service_name" 2>/dev/null)
      echo "服務狀態: $status"
      return 1
    fi
  fi

  echo "無法驗證服務狀態"
  return 1
}
