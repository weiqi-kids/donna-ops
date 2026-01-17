#!/usr/bin/env bash
###############################################
# analyzers/claude-analyzer.sh
# Claude CLI AI 分析器
#   - analyze_with_claude()     呼叫 Claude CLI 分析
#   - parse_claude_response()   解析 JSON 回應
#   - classify_severity()       嚴重度分類
###############################################

if [[ -n "${ANALYZER_CLAUDE_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ANALYZER_CLAUDE_SH_LOADED=1

# 設定
declare -g CLAUDE_CLI_PATH="${CLAUDE_CLI_PATH:-claude}"
declare -g CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-120}"
declare -g CLAUDE_DRY_RUN="${CLAUDE_DRY_RUN:-false}"

# 檢查 Claude CLI 是否可用
claude_available() {
  command -v "$CLAUDE_CLI_PATH" >/dev/null 2>&1
}

# 呼叫 Claude CLI 分析
# 用法：analyze_with_claude "alert_summary_json" "system_metrics_json" "log_samples"
analyze_with_claude() {
  local alert_summary="$1"
  local system_metrics="${2:-}"
  local log_samples="${3:-}"

  if ! claude_available; then
    echo '{"error": "Claude CLI not available", "analysis": null}'
    return 1
  fi

  if [[ "$CLAUDE_DRY_RUN" == "true" ]]; then
    echo '{"dry_run": true, "analysis": {"severity": "unknown", "diagnosis": "Dry run mode", "recommendations": []}}'
    return 0
  fi

  # 準備 prompt
  local prompt
  prompt=$(_build_analysis_prompt "$alert_summary" "$system_metrics" "$log_samples")

  # 呼叫 Claude CLI
  local response
  response=$(echo "$prompt" | timeout "$CLAUDE_TIMEOUT" "$CLAUDE_CLI_PATH" --print 2>&1)
  local exit_code=$?

  if (( exit_code != 0 )); then
    echo "{\"error\": \"Claude CLI failed with exit code $exit_code\", \"raw_response\": $(echo "$response" | jq -Rs '.')}"
    return 1
  fi

  # 解析回應
  parse_claude_response "$response"
}

# 建立分析 prompt
_build_analysis_prompt() {
  local alert_summary="$1"
  local system_metrics="$2"
  local log_samples="$3"

  local hostname
  hostname=$(hostname)
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  cat <<EOF
你是一個 Linux 系統維運專家。請分析以下系統警報並提供診斷和建議。

## 主機資訊
- 主機名稱：$hostname
- 時間：$timestamp

## 警報摘要
\`\`\`json
$alert_summary
\`\`\`

## 系統指標
\`\`\`json
$system_metrics
\`\`\`

## 最近日誌樣本
\`\`\`
$log_samples
\`\`\`

請以 JSON 格式回覆，包含以下欄位：
{
  "severity": "critical|high|medium|low",
  "diagnosis": "問題診斷說明",
  "root_cause": "可能的根本原因",
  "recommendations": [
    {
      "action": "建議的動作名稱",
      "description": "動作說明",
      "risk_level": "low|medium|high",
      "auto_executable": true/false,
      "command": "如果是可執行的命令，提供命令"
    }
  ],
  "requires_human": true/false,
  "urgency": "immediate|soon|can_wait"
}

注意：
1. 只回覆 JSON，不要有其他文字
2. risk_level 為 low 且 auto_executable 為 true 的動作才會被自動執行
3. 建議的動作應該安全且可逆
4. 如果情況不明確或可能造成服務中斷，請設定 requires_human 為 true
EOF
}

# 解析 Claude 回應
# 嘗試從回應中提取 JSON
parse_claude_response() {
  local response="$1"

  # 嘗試直接解析
  if echo "$response" | jq -e '.' >/dev/null 2>&1; then
    echo "$response" | jq '.'
    return 0
  fi

  # 嘗試從 markdown code block 中提取
  local json_block
  json_block=$(echo "$response" | sed -n '/```json/,/```/p' | sed '1d;$d')
  if [[ -n "$json_block" ]] && echo "$json_block" | jq -e '.' >/dev/null 2>&1; then
    echo "$json_block" | jq '.'
    return 0
  fi

  # 嘗試找到第一個 { 到最後一個 }
  local json_extract
  json_extract=$(echo "$response" | grep -oP '\{.*\}' | head -1)
  if [[ -n "$json_extract" ]] && echo "$json_extract" | jq -e '.' >/dev/null 2>&1; then
    echo "$json_extract" | jq '.'
    return 0
  fi

  # 無法解析，返回原始回應
  cat <<EOF
{
  "parse_error": true,
  "severity": "unknown",
  "diagnosis": "無法解析 Claude 回應",
  "raw_response": $(echo "$response" | jq -Rs '.'),
  "recommendations": [],
  "requires_human": true
}
EOF
}

# 嚴重度分類
# 用法：classify_severity "analysis_json"
classify_severity() {
  local analysis_json="$1"

  local severity
  severity=$(echo "$analysis_json" | jq -r '.severity // "unknown"')

  # 標準化嚴重度
  case "${severity,,}" in
    critical|crit)
      echo "critical"
      ;;
    high|major|error)
      echo "high"
      ;;
    medium|moderate|warning|warn)
      echo "medium"
      ;;
    low|minor|info)
      echo "low"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

# 取得可自動執行的修復動作
get_auto_executable_actions() {
  local analysis_json="$1"

  echo "$analysis_json" | jq '[.recommendations[] | select(.risk_level == "low" and .auto_executable == true)]'
}

# 取得需要人工確認的動作
get_human_required_actions() {
  local analysis_json="$1"

  echo "$analysis_json" | jq '[.recommendations[] | select(.risk_level != "low" or .auto_executable != true)]'
}

# 判斷是否需要人工介入
analysis_requires_human() {
  local analysis_json="$1"

  local requires
  requires=$(echo "$analysis_json" | jq -r '.requires_human // false')

  [[ "$requires" == "true" ]]
}

# 取得診斷摘要
get_diagnosis_summary() {
  local analysis_json="$1"

  local severity diagnosis urgency
  severity=$(echo "$analysis_json" | jq -r '.severity // "unknown"')
  diagnosis=$(echo "$analysis_json" | jq -r '.diagnosis // "無診斷資訊"')
  urgency=$(echo "$analysis_json" | jq -r '.urgency // "unknown"')

  cat <<EOF
嚴重度：$severity
緊急程度：$urgency
診斷：$diagnosis
EOF
}

# 格式化建議為人類可讀格式
format_recommendations() {
  local analysis_json="$1"

  local output=""
  local idx=1

  while IFS= read -r rec; do
    [[ -z "$rec" || "$rec" == "null" ]] && continue
    local action desc risk auto
    action=$(echo "$rec" | jq -r '.action')
    desc=$(echo "$rec" | jq -r '.description')
    risk=$(echo "$rec" | jq -r '.risk_level')
    auto=$(echo "$rec" | jq -r '.auto_executable')

    output+="$idx. $action\n"
    output+="   說明：$desc\n"
    output+="   風險：$risk | 自動執行：$auto\n\n"
    ((idx++))
  done < <(echo "$analysis_json" | jq -c '.recommendations[]' 2>/dev/null)

  echo -e "$output"
}

# 快速分析（不使用 Claude，只用規則）
quick_analysis() {
  local alert_summary="$1"

  local issue_count severity
  issue_count=$(echo "$alert_summary" | jq -r '.issue_count // 0')
  severity=$(echo "$alert_summary" | jq -r '.max_severity // "ok"')

  local diagnosis="系統狀態正常"
  local requires_human="false"
  local urgency="can_wait"
  local recommendations="[]"

  if (( issue_count > 0 )); then
    case "$severity" in
      critical)
        diagnosis="系統有嚴重問題需要立即處理"
        requires_human="true"
        urgency="immediate"
        ;;
      warning)
        diagnosis="系統有警告等級的問題"
        requires_human="false"
        urgency="soon"
        ;;
      minor)
        diagnosis="系統有輕微問題"
        requires_human="false"
        urgency="can_wait"
        ;;
    esac

    # 根據問題類型產生建議
    while IFS= read -r issue; do
      [[ -z "$issue" || "$issue" == "null" ]] && continue
      local type metric
      type=$(echo "$issue" | jq -r '.type')
      metric=$(echo "$issue" | jq -r '.metric // ""')

      case "$type" in
        threshold)
          case "$metric" in
            cpu|load_per_cpu)
              recommendations=$(echo "$recommendations" | jq '. + [{"action": "kill-runaway", "description": "終止佔用資源的程序", "risk_level": "medium", "auto_executable": false}]')
              ;;
            memory)
              recommendations=$(echo "$recommendations" | jq '. + [{"action": "clear-cache", "description": "清除系統快取", "risk_level": "low", "auto_executable": true}]')
              ;;
            disk:*)
              recommendations=$(echo "$recommendations" | jq '. + [{"action": "docker-prune", "description": "清理未使用的 Docker 資源", "risk_level": "low", "auto_executable": true}]')
              recommendations=$(echo "$recommendations" | jq '. + [{"action": "rotate-logs", "description": "輪替日誌檔案", "risk_level": "low", "auto_executable": true}]')
              ;;
          esac
          ;;
        docker)
          recommendations=$(echo "$recommendations" | jq '. + [{"action": "restart-service", "description": "重啟問題容器", "risk_level": "medium", "auto_executable": false}]')
          ;;
      esac
    done < <(echo "$alert_summary" | jq -c '.issues[]' 2>/dev/null)
  fi

  cat <<EOF
{
  "severity": "$severity",
  "diagnosis": "$diagnosis",
  "root_cause": "需要進一步分析",
  "recommendations": $(echo "$recommendations" | jq 'unique_by(.action)'),
  "requires_human": $requires_human,
  "urgency": "$urgency",
  "analysis_method": "rule_based"
}
EOF
}

# 設定 Claude CLI 路徑
set_claude_cli_path() {
  CLAUDE_CLI_PATH="$1"
}

# 設定超時時間
set_claude_timeout() {
  CLAUDE_TIMEOUT="$1"
}

# 設定 dry-run 模式
set_claude_dry_run() {
  local enabled="$1"
  case "${enabled,,}" in
    true|yes|1|on)  CLAUDE_DRY_RUN="true" ;;
    false|no|0|off) CLAUDE_DRY_RUN="false" ;;
  esac
}
