#!/usr/bin/env bash
###############################################
# uninstall.sh
# Donna-Ops 解除安裝腳本
###############################################

set -euo pipefail

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 設定
INSTALL_DIR="${INSTALL_DIR:-/opt/donna-ops}"
SYSTEMD_DIR="/etc/systemd/system"

# 輔助函式
log_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[OK]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*"
}

# 檢查是否為 root
check_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "此腳本需要 root 權限執行"
    log_info "請使用: sudo $0"
    exit 1
  fi
}

# 停止服務
stop_services() {
  log_info "停止服務..."

  # 停止 systemd 服務
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet donna-ops 2>/dev/null; then
      systemctl stop donna-ops
      log_info "已停止 donna-ops 服務"
    fi

    if systemctl is-active --quiet donna-ops-check.timer 2>/dev/null; then
      systemctl stop donna-ops-check.timer
      log_info "已停止 donna-ops-check timer"
    fi

    # 停用服務
    systemctl disable donna-ops 2>/dev/null || true
    systemctl disable donna-ops-check.timer 2>/dev/null || true
  fi

  # 停止可能運行中的程序
  if [[ -f "$INSTALL_DIR/state/periodic.pid" ]]; then
    local pid
    pid=$(cat "$INSTALL_DIR/state/periodic.pid" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      log_info "已停止定期檢查程序 (PID: $pid)"
    fi
  fi

  if [[ -f "$INSTALL_DIR/state/poller.pid" ]]; then
    local pid
    pid=$(cat "$INSTALL_DIR/state/poller.pid" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      log_info "已停止警報輪詢程序 (PID: $pid)"
    fi
  fi

  log_success "服務已停止"
}

# 移除 systemd 設定
remove_systemd() {
  if [[ "$(uname)" == "Darwin" ]]; then
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  log_info "移除 systemd 設定..."

  local files=(
    "$SYSTEMD_DIR/donna-ops.service"
    "$SYSTEMD_DIR/donna-ops-check.service"
    "$SYSTEMD_DIR/donna-ops-check.timer"
  )

  for file in "${files[@]}"; do
    if [[ -f "$file" ]]; then
      rm -f "$file"
      log_info "已移除: $file"
    fi
  done

  systemctl daemon-reload

  log_success "systemd 設定已移除"
}

# 移除檔案
remove_files() {
  log_info "移除檔案..."

  # 移除符號連結
  if [[ -L /usr/local/bin/donna-ops ]]; then
    rm -f /usr/local/bin/donna-ops
    log_info "已移除: /usr/local/bin/donna-ops"
  fi

  # 備份設定檔
  if [[ -f "$INSTALL_DIR/config/config.yaml" ]]; then
    local backup_file="/tmp/donna-ops-config-backup-$(date +%Y%m%d%H%M%S).yaml"
    cp "$INSTALL_DIR/config/config.yaml" "$backup_file"
    log_info "設定檔已備份到: $backup_file"
  fi

  # 詢問是否保留日誌
  local keep_logs="n"
  if [[ -d "$INSTALL_DIR/logs" ]]; then
    read -p "是否保留日誌檔案？(y/n): " keep_logs
  fi

  # 移除安裝目錄
  if [[ -d "$INSTALL_DIR" ]]; then
    if [[ "${keep_logs,,}" == "y" ]]; then
      # 保留日誌，移除其他
      local backup_logs="/tmp/donna-ops-logs-$(date +%Y%m%d%H%M%S)"
      mv "$INSTALL_DIR/logs" "$backup_logs"
      log_info "日誌已移動到: $backup_logs"
    fi

    rm -rf "$INSTALL_DIR"
    log_info "已移除: $INSTALL_DIR"
  fi

  log_success "檔案已移除"
}

# 顯示完成訊息
show_completion() {
  echo ""
  echo "╔════════════════════════════════════════╗"
  echo "║   Donna-Ops 已解除安裝                 ║"
  echo "╚════════════════════════════════════════╝"
  echo ""
  log_info "依賴套件 (jq, bc, yq, gh) 未被移除"
  log_info "如需移除請手動執行"
  echo ""
}

# 確認解除安裝
confirm_uninstall() {
  echo ""
  echo "╔════════════════════════════════════════╗"
  echo "║   Donna-Ops 解除安裝程式               ║"
  echo "╚════════════════════════════════════════╝"
  echo ""

  if [[ ! -d "$INSTALL_DIR" ]]; then
    log_error "Donna-Ops 未安裝於 $INSTALL_DIR"
    exit 1
  fi

  log_warn "這將會移除 Donna-Ops 及其所有設定"

  read -p "確定要繼續嗎？(yes/no): " confirm
  if [[ "${confirm,,}" != "yes" ]]; then
    log_info "已取消"
    exit 0
  fi
}

# 主函式
main() {
  # macOS 不需要 root
  if [[ "$(uname)" != "Darwin" ]]; then
    check_root
  fi

  confirm_uninstall
  stop_services
  remove_systemd
  remove_files
  show_completion
}

main "$@"
