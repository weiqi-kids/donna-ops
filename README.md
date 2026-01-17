# Donna-Ops 自動化維運框架

Donna-Ops 是一個專為 Linode 伺服器設計的自動化維運框架，提供系統監控、問題偵測、自動修復與通知功能。

## 功能特色

- **自動監控** - 監控 CPU、記憶體、磁碟使用率，輪詢 Linode Alert API
- **問題追蹤** - 發現問題時自動建立 GitHub Issue，問題解決後自動關閉
- **自動修復** - 低風險問題（清快取、Docker prune、日誌輪替）自動執行
- **AI 分析** - 複雜問題使用 Claude CLI 分析並建議修復方式
- **即時通知** - 透過 Slack/Telegram 發送警報

## 專案結構

```
donna-ops/
├── donna-ops.sh              # 主入口點
├── install.sh                # 安裝腳本
├── uninstall.sh              # 解除安裝腳本
├── config/
│   ├── config.yaml.example   # 設定範本
│   └── remediation-rules.yaml
├── lib/                      # 核心函式庫
│   ├── config.sh             # YAML 設定解析
│   ├── logging.sh            # 結構化日誌
│   ├── state.sh              # 狀態管理
│   ├── notify.sh             # 通知功能
│   └── pipeline.sh           # 統一處理流程
├── collectors/               # 資料收集器
│   ├── system.sh             # 系統指標
│   ├── docker.sh             # Docker 狀態
│   ├── logs.sh               # 日誌收集
│   └── linode.sh             # Linode Alert
├── analyzers/                # 分析器
│   ├── threshold-checker.sh  # 閾值檢查
│   └── claude-analyzer.sh    # Claude AI 分析
├── remediation/              # 修復系統
│   ├── executor.sh           # 執行器
│   ├── validators/
│   │   └── safety-check.sh   # 安全檢查
│   └── actions/              # 修復動作
│       ├── clear-cache.sh
│       ├── rotate-logs.sh
│       ├── docker-prune.sh
│       ├── restart-service.sh
│       └── kill-runaway.sh
├── integrations/             # 整合
│   ├── github-issues.sh      # GitHub Issue
│   └── linode-alerts.sh      # Linode Alert
├── triggers/                 # 觸發器
│   ├── cron-periodic.sh      # 定期檢查
│   └── alert-poller.sh       # 警報輪詢
├── state/                    # 執行時狀態
└── logs/                     # 日誌目錄
```

## Ubuntu 安裝

### 1. 安裝依賴

```bash
# 安裝必要工具
sudo apt-get update
sudo apt-get install -y jq bc curl

# 安裝 yq (YAML 解析器)
sudo wget https://github.com/mikefarah/yq/releases/download/v4.35.1/yq_linux_amd64 -O /usr/local/bin/yq
sudo chmod +x /usr/local/bin/yq

# 安裝 GitHub CLI
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update && sudo apt-get install -y gh

# 認證 GitHub CLI
gh auth login
```

### 2. 設定

```bash
# 複製設定範本
cp config/config.yaml.example config/config.yaml

# 編輯設定
nano config/config.yaml
```

**必填設定：**

```yaml
host_name: "my-linode-server"
linode_api_token: "你的 Linode API Token"
linode_instance_id: "12345678"
github_repo: "auto"  # 設為 "auto" 或留空會自動從 git remote 偵測

thresholds:
  cpu_percent: 80
  memory_percent: 85
  disk_percent: 90

# 檢查間隔（設為 -1 可停用該功能）
intervals:
  periodic_check_minutes: 5   # -1 停用定期檢查
  alert_poll_seconds: 60      # -1 停用警報輪詢

# 通知設定（全部選填，可不設定）
notifications:
  slack_webhook: ""
  telegram_bot_token: ""
  telegram_chat_id: ""
```

## 執行方式

### 方式一：手動執行單次檢查

```bash
# 執行系統檢查
./donna-ops.sh check

# 模擬執行（不實際修復）
./donna-ops.sh check --dry-run

# 完整診斷（含 AI 分析）
./donna-ops.sh diagnose --ai
```

### 方式二：前景持續執行

```bash
# 前景執行 daemon（會同時啟動定期檢查和警報輪詢）
./donna-ops.sh daemon --foreground
```

### 方式三：使用 systemd 持續執行（推薦）

```bash
# 使用安裝腳本（會自動設定 systemd）
sudo ./install.sh

# 或手動建立 systemd service
sudo cat > /etc/systemd/system/donna-ops.service << 'EOF'
[Unit]
Description=Donna-Ops Automation Framework
After=network.target docker.service

[Service]
Type=simple
ExecStart=/opt/donna-ops/donna-ops.sh daemon --foreground
Restart=always
RestartSec=10
User=root
WorkingDirectory=/opt/donna-ops

[Install]
WantedBy=multi-user.target
EOF

# 啟動服務
sudo systemctl daemon-reload
sudo systemctl enable donna-ops
sudo systemctl start donna-ops

# 查看狀態
sudo systemctl status donna-ops
```

## 查看狀態與日誌

```bash
# 查看目前狀態
./donna-ops.sh status

# 查看即時日誌
tail -f logs/donna-ops.log

# 查看稽核紀錄（修復動作記錄）
tail -f logs/audit.log
```

## 運作流程

### 完整系統架構圖

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              donna-ops.sh                                   │
│                            (主入口 / CLI)                                    │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐       │
│  │  check   │  │  daemon  │  │ diagnose │  │  status  │  │ version  │       │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘  └──────────┘       │
└───────┼─────────────┼─────────────┼─────────────┼───────────────────────────┘
        │             │             │             │
        │     ┌───────┴───────┐     │             │
        │     ▼               ▼     │             │
        │  ┌─────────────────────────────────────────────────────────────┐
        │  │                     觸發層 (triggers/)                       │
        │  ├─────────────────────────┬───────────────────────────────────┤
        │  │   cron-periodic.sh      │      alert-poller.sh              │
        │  │   定期檢查觸發器          │      Linode 警報輪詢器             │
        │  │   (預設每 5 分鐘)         │      (預設每 60 秒)                │
        │  │   interval=-1 停用       │      interval=-1 停用             │
        │  └────────────┬────────────┴──────────────┬────────────────────┘
        │               │                           │
        │               ▼                           ▼
        │  ┌─────────────────────────────────────────────────────────────┐
        │  │                   資料收集層 (collectors/)                   │
        │  ├──────────────┬──────────────┬──────────────┬────────────────┤
        │  │  system.sh   │  docker.sh   │   logs.sh    │   linode.sh   │
        │  │  ─────────   │  ──────────  │   ────────   │   ──────────  │
        │  │  • CPU 使用率 │  • 容器狀態   │  • journald  │  • Alert API  │
        │  │  • 記憶體     │  • 健康檢查   │  • syslog    │  • 警報偵測    │
        │  │  • 磁碟空間   │  • 資源統計   │  • 錯誤摘要   │  • 新警報比對  │
        │  │  • 系統負載   │  • unhealthy │  • docker    │               │
        │  │  • Top 程序  │    容器列表   │    logs     │               │
        │  └──────────────┴──────────────┴──────────────┴────────────────┘
        │               │                           │
        │               ▼                           ▼
        │  ┌─────────────────────────────────────────────────────────────┐
        │  │                     分析層 (analyzers/)                      │
        │  ├───────────────────────────┬─────────────────────────────────┤
        │  │   threshold-checker.sh    │     claude-analyzer.sh          │
        │  │   ────────────────────    │     ──────────────────          │
        │  │   • 閾值比對              │     • Claude CLI 整合            │
        │  │   • 違規偵測              │     • AI 診斷分析                │
        │  │   • 嚴重度分類            │     • 修復建議產生               │
        │  │   • alert_summary 產生   │     • 嚴重度評估                 │
        │  └───────────────────────────┴─────────────────────────────────┘
        │               │
        │               ▼
        ▼  ┌─────────────────────────────────────────────────────────────┐
┌──────────┤             統一處理流程 (lib/pipeline.sh)                    │
│          │                    pipeline_process()                        │
│          ├─────────────────────────────────────────────────────────────┤
│          │                                                             │
│          │   有問題？ ─── 是 ──→ _pipeline_handle_issues()             │
│          │      │                     │                                │
│          │      │                     ├─ Step 1: _pipeline_diagnose()  │
│          │      │                     │          規則分析 或 AI 分析     │
│          │      │                     │                                │
│          │      │                     ├─ Step 2: _pipeline_manage_issues()
│          │      │                     │          建立/更新 GitHub Issue  │
│          │      │                     │                                │
│          │      │                     ├─ Step 3: _pipeline_auto_remediate()
│          │      │                     │          執行低風險自動修復      │
│          │      │                     │                                │
│          │      │                     └─ Step 4: _pipeline_notify()    │
│          │      │                                發送 Slack/Telegram   │
│          │      │                                                      │
│          │      └─ 否 ──→ _pipeline_check_resolved()                   │
│          │                     │                                       │
│          │                     └─ 連續 N 次正常 → 自動關閉 Issue         │
│          │                                                             │
│          └─────────────────────────────────────────────────────────────┘
│                    │                │                │
│                    ▼                ▼                ▼
│  ┌─────────────────────────────────────────────────────────────────────┐
│  │                       整合層 (integrations/)                         │
│  ├────────────────────────────────┬────────────────────────────────────┤
│  │       github-issues.sh         │        linode-alerts.sh            │
│  │       ─────────────────        │        ────────────────            │
│  │       • create_issue()         │        • fetch_active_alerts()     │
│  │       • update_issue()         │        • detect_new_alerts()       │
│  │       • close_issue()          │        • correlate_with_issues()   │
│  │       • find_existing_issue()  │                                    │
│  └────────────────────────────────┴────────────────────────────────────┘
│                    │
│                    ▼
│  ┌─────────────────────────────────────────────────────────────────────┐
│  │                       修復層 (remediation/)                          │
│  ├─────────────────────────────────────────────────────────────────────┤
│  │  executor.sh                        validators/safety-check.sh      │
│  │  ────────────                       ───────────────────────         │
│  │  • execute_remediation()            • is_low_risk_action()          │
│  │  • execute_with_timeout()           • check_system_stability()      │
│  │  • verify_success()                 • validate_command_safety()     │
│  ├─────────────────────────────────────────────────────────────────────┤
│  │  actions/                                                           │
│  │  ┌──────────────┬──────────────┬──────────────┬──────────────┐      │
│  │  │ clear-cache  │ docker-prune │ rotate-logs  │restart-service│     │
│  │  │   (Low)      │    (Low)     │    (Low)     │   (Medium)   │      │
│  │  └──────────────┴──────────────┴──────────────┴──────────────┘      │
│  │  ┌──────────────┐                                                   │
│  │  │ kill-runaway │                                                   │
│  │  │   (Medium)   │                                                   │
│  │  └──────────────┘                                                   │
│  └─────────────────────────────────────────────────────────────────────┘
│                    │
│                    ▼
│  ┌─────────────────────────────────────────────────────────────────────┐
│  │                         通知層 (lib/notify.sh)                       │
│  ├────────────────────────────────┬────────────────────────────────────┤
│  │         notify_slack()         │         notify_telegram()          │
│  │         Slack Webhook          │         Telegram Bot API           │
│  └────────────────────────────────┴────────────────────────────────────┘
│
│  ┌─────────────────────────────────────────────────────────────────────┐
│  │                       核心函式庫 (lib/)                               │
│  ├───────────┬───────────┬───────────┬───────────┬───────────┬─────────┤
│  │ config.sh │logging.sh │ state.sh  │ notify.sh │  core.sh  │ args.sh │
│  │ ───────── │ ───────── │ ───────── │ ───────── │ ───────── │ ─────── │
│  │ YAML 解析 │ 結構化日誌│ 狀態管理  │ 通知功能  │ 依賴檢查  │ 參數解析│
│  │ 自動偵測  │ 稽核紀錄  │ 檔案鎖定  │ Slack/TG │           │         │
│  │ github    │           │ 冷卻管理  │           │           │         │
│  └───────────┴───────────┴───────────┴───────────┴───────────┴─────────┘
│
│  ┌─────────────────────────────────────────────────────────────────────┐
│  │                         儲存層                                       │
│  ├───────────────────────────────┬─────────────────────────────────────┤
│  │          state/               │             logs/                   │
│  │          ──────               │             ─────                   │
│  │          • issues.json        │             • donna-ops.log         │
│  │          • cooldowns/         │             • audit.log             │
│  │          • *.pid              │             • periodic.log          │
│  │          • .lock              │             • poller.log            │
│  └───────────────────────────────┴─────────────────────────────────────┘
└────────────────────────────────────────────────────────────────────────────
```

### Issue 生命週期

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          Issue 狀態機                                     │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│    ┌─────────┐     偵測到問題      ┌─────────┐                           │
│    │  正常   │ ──────────────────→ │ 建立中  │                           │
│    │ (無Issue)│                    │         │                           │
│    └─────────┘                     └────┬────┘                           │
│         ▲                               │                                │
│         │                               │ 建立 GitHub Issue              │
│         │                               │ 記錄 state                     │
│         │                               ▼                                │
│         │                          ┌─────────┐                           │
│         │                          │  開啟   │◀──┐                       │
│         │                          │ (Open)  │   │                       │
│         │                          └────┬────┘   │                       │
│         │                               │        │                       │
│         │              ┌────────────────┼────────┘                       │
│         │              │                │                                │
│         │         問題持續存在      問題消失                               │
│         │         (更新 Issue)     (normal_count++)                      │
│         │                               │                                │
│         │                               ▼                                │
│         │                    normal_count >= 3?                          │
│         │                          │         │                           │
│         │                         否         是                          │
│         │                          │         │                           │
│         │                          │         ▼                           │
│         │                          │    ┌─────────┐                      │
│         │                          │    │ 關閉中  │                      │
│         │                          │    │         │                      │
│         │                          │    └────┬────┘                      │
│         │                          │         │                           │
│         │                          │         │ 關閉 GitHub Issue          │
│         │                          │         │ 刪除 state                 │
│         │                          │         │ 發送通知                   │
│         │                          │         ▼                           │
│         └──────────────────────────┴────  ┌─────────┐                    │
│                                           │  已解決  │                    │
│                                           │(Resolved)│                    │
│                                           └─────────┘                    │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### 資料流

不論問題來源是「系統指標超標」或「Linode 警報」，都會產生統一格式的 `alert_summary`，然後交由 `pipeline.sh` 處理。這樣的設計確保：

- **一致性** - 所有問題都經過相同的處理流程
- **可維護性** - 修改處理邏輯只需改一處
- **可擴充性** - 新增觸發來源只需產生 `alert_summary` 即可

### alert_summary 格式

```json
{
  "timestamp": "2024-01-15T10:30:00Z",
  "hostname": "my-server",
  "issue_count": 2,
  "max_severity": "warning",
  "summary": "CPU 超過閾值、記憶體超過閾值",
  "issues": [
    {
      "type": "threshold",
      "metric": "cpu",
      "current": 92,
      "threshold": 80,
      "severity": "warning"
    },
    {
      "type": "threshold",
      "metric": "memory",
      "current": 88,
      "threshold": 85,
      "severity": "warning"
    }
  ]
}
```

## 修復動作風險分級

| 風險等級 | 自動執行 | 需 AI 建議 | 需人工確認 | 範例 |
|---------|---------|-----------|-----------|------|
| Low | ✓ | - | - | 清快取、Docker prune、日誌輪替 |
| Medium | - | ✓ | - | 重啟服務、終止程序 |
| High | - | ✓ | ✓ | 重啟 Docker daemon |
| Critical | - | ✓ | ✓ | 系統重啟 |

## 命令列參考

```bash
# 顯示幫助
./donna-ops.sh --help

# 顯示版本
./donna-ops.sh version

# 系統檢查
./donna-ops.sh check [--dry-run]

# 完整診斷
./donna-ops.sh diagnose [--full] [--ai] [--output json|text]

# 啟動 daemon
./donna-ops.sh daemon [--periodic] [--alert-poller] [--foreground]

# 查看狀態
./donna-ops.sh status [--json] [--issues]
```

## 設定檔說明

完整設定範例請參考 `config/config.yaml.example`。

### 主要設定項目

| 設定項 | 說明 | 預設值 |
|--------|------|--------|
| `host_name` | 主機識別名稱 | - |
| `linode_api_token` | Linode API Token（[取得方式](https://cloud.linode.com/profile/tokens)） | - |
| `linode_instance_id` | Linode 實例 ID | - |
| `github_repo` | GitHub 儲存庫，設為 `auto` 或留空可自動偵測 | auto |
| `thresholds.*` | 各項指標的警告閾值 | 80/85/90 |
| `intervals.*` | 檢查間隔，設為 `-1` 可停用 | 5min/60s |
| `notifications.*` | Slack/Telegram 通知設定（全部選填） | - |

### 特殊設定說明

**github_repo 自動偵測**
```yaml
# 以下三種寫法等效，都會自動從 git remote 偵測
github_repo: "auto"
github_repo: ""
# 或不設定此欄位
```

**停用功能**
```yaml
intervals:
  periodic_check_minutes: -1   # 停用定期檢查
  alert_poll_seconds: -1       # 停用警報輪詢
```

**選填通知**
```yaml
# 通知設定全部選填，可以只設定 Slack 或只設定 Telegram，或都不設定
notifications:
  slack_webhook: "https://hooks.slack.com/..."
  telegram_bot_token: ""    # 留空表示不使用
  telegram_chat_id: ""
```

## 授權

MIT License
