#!/usr/bin/env bash
# time.sh
# 通用時間工具（sleep / next boundary）
# 不在這裡 set -euo pipefail，交給呼叫端決定。

if [[ -n "${TIME_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
TIME_SH_LOADED=1

# 依賴：GNU date（Linux），需要支援 date -d "@<epoch>"
# 若要支援 macOS，請自行改成 gdate 或做平台分支。

sleep_until_next_hour() {
  local now_ts next_ts sleep_sec
  now_ts="$(date +%s)"
  next_ts=$(( (now_ts/3600 + 1) * 3600 ))
  sleep_sec=$(( next_ts - now_ts ))
  echo "😴 下一次醒來：$(date -d "@$next_ts" '+%Y-%m-%d %H:%M:%S')（${sleep_sec}s）"
  sleep "$sleep_sec"
}

# 需要外部先設定 START_HOUR / END_HOUR（或你也可以改成參數式）
sleep_until_next_start_hour() {
  local now_ts hour target_ts sleep_sec
  now_ts="$(date +%s)"
  hour="$(date +%H)"

  if (( 10#$hour < 10#${START_HOUR} )); then
    target_ts="$(date -d "today ${START_HOUR}:00:00" +%s)"
  else
    target_ts="$(date -d "tomorrow ${START_HOUR}:00:00" +%s)"
  fi

  sleep_sec=$(( target_ts - now_ts ))
  echo "🚫 本次任務：不在時段（${START_HOUR}–${END_HOUR}）"
  echo "😴 睡到：$(date -d "@$target_ts" '+%Y-%m-%d %H:%M:%S')（${sleep_sec}s）"
  sleep "$sleep_sec"
}