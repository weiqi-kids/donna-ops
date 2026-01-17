#!/usr/bin/env bash
###############################################
# install.sh
# Donna-Ops 安裝腳本
#
# 功能：
#   1. 驗證系統需求
#   2. 檢查/安裝依賴
#   3. 設定 GitHub CLI 認證
#   4. 複製腳本到目標目錄
#   5. 建立設定檔
#   6. 設定 systemd service（可選）
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
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# 檢查系統
check_system() {
  log_info "檢查系統..."

  local os_name=""
  local os_version=""

  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    os_name="$ID"
    os_version="$VERSION_ID"
  elif [[ "$(uname)" == "Darwin" ]]; then
    os_name="macos"
    os_version="$(sw_vers -productVersion)"
  else
    log_error "無法識別作業系統"
    exit 1
  fi

  log_info "作業系統: $os_name $os_version"

  case "$os_name" in
    ubuntu)
      if [[ "${os_version%%.*}" -lt 20 ]]; then
        log_warn "建議使用 Ubuntu 20.04 或更新版本"
      fi
      ;;
    debian)
      if [[ "${os_version%%.*}" -lt 11 ]]; then
        log_warn "建議使用 Debian 11 或更新版本"
      fi
      ;;
    macos)
      log_info "macOS 支援有限，某些功能可能無法使用"
      ;;
    *)
      log_warn "未經測試的作業系統: $os_name"
      ;;
  esac

  log_success "系統檢查完成"
}

# 檢查並安裝依賴
check_dependencies() {
  log_info "檢查依賴..."

  local missing=()

  # 必要依賴
  local deps=(jq bc curl)
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing+=("$dep")
    fi
  done

  # yq
  if ! command -v yq >/dev/null 2>&1; then
    missing+=("yq")
  fi

  # gh CLI
  if ! command -v gh >/dev/null 2>&1; then
    missing+=("gh")
  fi

  # Claude CLI（可選）
  if ! command -v claude >/dev/null 2>&1; then
    log_warn "Claude CLI 未安裝（AI 分析功能將不可用）"
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_info "需要安裝: ${missing[*]}"

    read -p "是否要自動安裝依賴？(y/n): " confirm
    if [[ "${confirm,,}" != "y" ]]; then
      log_error "請手動安裝依賴後重試"
      exit 1
    fi

    install_dependencies "${missing[@]}"
  fi

  log_success "依賴檢查完成"
}

# 安裝依賴
install_dependencies() {
  local deps=("$@")

  local os_name=""
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    os_name="$ID"
  elif [[ "$(uname)" == "Darwin" ]]; then
    os_name="macos"
  fi

  for dep in "${deps[@]}"; do
    log_info "安裝 $dep..."

    case "$os_name" in
      ubuntu|debian)
        case "$dep" in
          jq|bc|curl)
            apt-get update -qq && apt-get install -y "$dep"
            ;;
          yq)
            # 安裝 yq (mikefarah/yq)
            local yq_version="v4.35.1"
            local yq_binary="yq_linux_amd64"
            [[ "$(uname -m)" == "aarch64" ]] && yq_binary="yq_linux_arm64"
            wget -q "https://github.com/mikefarah/yq/releases/download/${yq_version}/${yq_binary}" -O /usr/local/bin/yq
            chmod +x /usr/local/bin/yq
            ;;
          gh)
            # 安裝 GitHub CLI
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
            chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
            apt-get update -qq && apt-get install -y gh
            ;;
        esac
        ;;
      macos)
        if ! command -v brew >/dev/null 2>&1; then
          log_error "請先安裝 Homebrew"
          exit 1
        fi
        brew install "$dep"
        ;;
      *)
        log_error "不支援自動安裝依賴於 $os_name"
        exit 1
        ;;
    esac

    if command -v "$dep" >/dev/null 2>&1; then
      log_success "$dep 安裝完成"
    else
      log_error "$dep 安裝失敗"
      exit 1
    fi
  done
}

# 設定 GitHub CLI 認證
setup_github_auth() {
  log_info "檢查 GitHub CLI 認證..."

  if gh auth status >/dev/null 2>&1; then
    log_success "GitHub CLI 已認證"
    return 0
  fi

  log_info "需要設定 GitHub CLI 認證"
  log_info "請按照提示完成認證..."

  gh auth login

  if gh auth status >/dev/null 2>&1; then
    log_success "GitHub CLI 認證完成"
  else
    log_error "GitHub CLI 認證失敗"
    exit 1
  fi
}

# 安裝檔案
install_files() {
  log_info "安裝檔案到 $INSTALL_DIR..."

  # 建立目錄
  mkdir -p "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR/state"
  mkdir -p "$INSTALL_DIR/logs"

  # 複製檔案
  cp -r "$SOURCE_DIR/lib" "$INSTALL_DIR/"
  cp -r "$SOURCE_DIR/collectors" "$INSTALL_DIR/"
  cp -r "$SOURCE_DIR/analyzers" "$INSTALL_DIR/"
  cp -r "$SOURCE_DIR/remediation" "$INSTALL_DIR/"
  cp -r "$SOURCE_DIR/integrations" "$INSTALL_DIR/"
  cp -r "$SOURCE_DIR/triggers" "$INSTALL_DIR/"
  cp -r "$SOURCE_DIR/config" "$INSTALL_DIR/"
  cp "$SOURCE_DIR/donna-ops.sh" "$INSTALL_DIR/"

  # 設定執行權限
  chmod +x "$INSTALL_DIR/donna-ops.sh"
  chmod +x "$INSTALL_DIR/triggers"/*.sh

  # 建立符號連結
  ln -sf "$INSTALL_DIR/donna-ops.sh" /usr/local/bin/donna-ops

  log_success "檔案安裝完成"
}

# 設定設定檔
setup_config() {
  log_info "設定設定檔..."

  local config_file="$INSTALL_DIR/config/config.yaml"

  if [[ -f "$config_file" ]]; then
    log_warn "設定檔已存在，跳過"
    return 0
  fi

  cp "$INSTALL_DIR/config/config.yaml.example" "$config_file"

  log_info "請編輯設定檔: $config_file"
  log_info "必填欄位："
  log_info "  - linode_api_token"
  log_info "  - linode_instance_id"
  log_info "  - github_repo"

  read -p "是否現在編輯設定檔？(y/n): " confirm
  if [[ "${confirm,,}" == "y" ]]; then
    ${EDITOR:-nano} "$config_file"
  fi

  log_success "設定檔已建立"
}

# 設定 systemd service
setup_systemd() {
  if [[ "$(uname)" == "Darwin" ]]; then
    log_info "macOS 不支援 systemd，跳過"
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    log_warn "systemd 不可用，跳過"
    return 0
  fi

  log_info "設定 systemd service..."

  # 建立 service 檔案
  cat > "$SYSTEMD_DIR/donna-ops.service" <<EOF
[Unit]
Description=Donna-Ops Automation Framework
After=network.target docker.service

[Service]
Type=simple
ExecStart=$INSTALL_DIR/donna-ops.sh daemon --foreground
Restart=always
RestartSec=10
User=root
WorkingDirectory=$INSTALL_DIR

# 日誌
StandardOutput=append:$INSTALL_DIR/logs/service.log
StandardError=append:$INSTALL_DIR/logs/service.log

[Install]
WantedBy=multi-user.target
EOF

  # 建立 timer 檔案（用於定期檢查，如果不使用 daemon 模式）
  cat > "$SYSTEMD_DIR/donna-ops-check.service" <<EOF
[Unit]
Description=Donna-Ops Periodic Check
After=network.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/donna-ops.sh check
User=root
WorkingDirectory=$INSTALL_DIR
EOF

  cat > "$SYSTEMD_DIR/donna-ops-check.timer" <<EOF
[Unit]
Description=Donna-Ops Periodic Check Timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # 重新載入 systemd
  systemctl daemon-reload

  log_info "systemd service 已建立"
  log_info "啟動服務: systemctl start donna-ops"
  log_info "或使用 timer: systemctl enable --now donna-ops-check.timer"

  read -p "是否要啟動 donna-ops 服務？(y/n): " confirm
  if [[ "${confirm,,}" == "y" ]]; then
    systemctl enable donna-ops
    systemctl start donna-ops
    log_success "服務已啟動"
  fi
}

# 執行驗證
run_verification() {
  log_info "執行驗證..."

  # 檢查命令
  if ! donna-ops version >/dev/null 2>&1; then
    log_error "donna-ops 命令無法執行"
    exit 1
  fi

  # 執行 dry-run 檢查
  log_info "執行測試檢查..."
  donna-ops check --dry-run || {
    log_warn "測試檢查有警告，請檢查設定"
  }

  log_success "驗證完成"
}

# 顯示完成訊息
show_completion() {
  echo ""
  echo "╔════════════════════════════════════════╗"
  echo "║   Donna-Ops 安裝完成！                 ║"
  echo "╚════════════════════════════════════════╝"
  echo ""
  echo "安裝目錄: $INSTALL_DIR"
  echo ""
  echo "下一步："
  echo "  1. 編輯設定檔: $INSTALL_DIR/config/config.yaml"
  echo "  2. 執行檢查: donna-ops check"
  echo "  3. 啟動服務: donna-ops daemon --foreground"
  echo ""
  echo "常用命令："
  echo "  donna-ops check        # 單次系統檢查"
  echo "  donna-ops diagnose     # 完整診斷"
  echo "  donna-ops status       # 查看狀態"
  echo "  donna-ops --help       # 顯示幫助"
  echo ""
}

# 主函式
main() {
  echo ""
  echo "╔════════════════════════════════════════╗"
  echo "║   Donna-Ops 安裝程式                   ║"
  echo "╚════════════════════════════════════════╝"
  echo ""

  # macOS 不需要 root
  if [[ "$(uname)" != "Darwin" ]]; then
    check_root
  fi

  check_system
  check_dependencies
  setup_github_auth
  install_files
  setup_config
  setup_systemd
  run_verification
  show_completion
}

main "$@"
