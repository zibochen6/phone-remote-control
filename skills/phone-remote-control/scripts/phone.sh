#!/usr/bin/env bash
# ============================================================================
# phone.sh — 通用 Android 手机控制入口
#
# 一个脚本，三种连接方式：
#   usb        USB 数据线
#   wifi       无线调试（Android 11+，零安装）      ← 推荐
#   tailscale  Tailscale 异地穿透（在外网控制家里手机）
#
# 设计目标：给 AI agent 用。优先按「文字」操作而不是坐标，命令自带超时，
# 失败有明确提示，不会挂死。
#
# 依赖：adb（必需）、python3（UI 解析，推荐）、scrcpy（投屏可选）、
#       tailscale（仅 tailscale 模式需要）
#
# 用法：phone.sh <子命令> [参数...]     完整列表：phone.sh help
#
# 配置：~/.phone-remote.conf（首次运行自动生成）
# 环境变量：
#   PHONE_MODE          auto|usb|wifi|tailscale（默认 auto）
#   PHONE_SERIAL        指定设备序列号 / IP:端口（多机时用）
#   PHONE_CONF          配置文件路径
#   PHONE_IP            直接钉死 Tailscale IP
#   PHONE_HOST          Tailscale 主机名
#   ADB_BIN / SCRCPY_BIN / TAILSCALE_BIN   覆盖工具路径
#   PHONE_ADB_TIMEOUT   单条 adb 命令超时秒数（默认 20）
#   PHONE_ALLOW_REBOOT  设为 1 才允许 reboot
# ============================================================================
set -uo pipefail

VERSION="1.0.0"
CONF="${PHONE_CONF:-$HOME/.phone-remote.conf}"
PORT_DEFAULT=5555
ADB_TIMEOUT="${PHONE_ADB_TIMEOUT:-20}"
MODE="${PHONE_MODE:-auto}"

# 解析脚本真实路径（支持软链接调用，如 ~/.local/bin/phone）
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  _dir="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  case "$SOURCE" in /*) ;; *) SOURCE="$_dir/$SOURCE" ;; esac
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
unset _dir
UI_PARSE="$SCRIPT_DIR/ui_parse.py"

# ---------------------------------------------------------------- 工具定位
find_bin() {
  local c
  for c in "$@"; do
    [ -n "$c" ] || continue
    if [ -x "$c" ]; then printf '%s\n' "$c"; return 0; fi
    if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return 0; fi
  done
  return 1
}

# PHONE_FORCE_NO_ADB=1 用于测试「没装 adb」的路径
if [ "${PHONE_FORCE_NO_ADB:-0}" = "1" ]; then
  ADB=""
else
  ADB="$(find_bin "${ADB_BIN:-}" adb /opt/homebrew/bin/adb /usr/local/bin/adb \
          "$HOME/Library/Android/sdk/platform-tools/adb" "$HOME/Android/Sdk/platform-tools/adb" || true)"
fi

# adb 缺失时不要立刻退出：help / --version / doctor 仍然应该能用，
# 否则用户装不上 adb 时连帮助都看不到。真正需要设备的命令才报错。
require_adb() {
  [ -n "$ADB" ] && return 0
  echo "错误：未找到 adb。" >&2
  echo "  macOS : brew install --cask android-platform-tools" >&2
  echo "  Linux : sudo apt install android-tools-adb" >&2
  echo "  Win   : 下载 https://developer.android.com/studio/releases/platform-tools" >&2
  echo "" >&2
  echo "装好后重新运行本命令即可。查看全部命令：phone.sh help" >&2
  exit 127
}
SCRCPY="$(find_bin "${SCRCPY_BIN:-}" scrcpy /opt/homebrew/bin/scrcpy /usr/local/bin/scrcpy || true)"
TS="$(find_bin "${TAILSCALE_BIN:-}" tailscale /usr/local/bin/tailscale \
       /Applications/Tailscale.app/Contents/MacOS/Tailscale /opt/homebrew/bin/tailscale || true)"

# ---------------------------------------------------------------- 超时包装
# 防止 adb 在手机掉线时无限挂起（agent 场景下这是致命的）
_timeout() {
  local t="$1"; shift
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$t" "$@"; return $?; fi
  if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"; return $?; fi
  "$@" &
  local pid=$!
  ( sleep "$t"; kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local wd=$!
  wait "$pid"; local rc=$?
  kill "$wd" >/dev/null 2>&1
  wait "$wd" >/dev/null 2>&1
  if [ "$rc" -eq 137 ] || [ "$rc" -eq 143 ]; then
    echo "⚠ 命令超时（${t}s），已中止" >&2
    return 124
  fi
  return $rc
}

adbt() { _timeout "$ADB_TIMEOUT" "$ADB" "$@"; }

# ---------------------------------------------------------------- 配置
conf_get() { [ -f "$CONF" ] && awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' "$CONF"; }
conf_set() {
  local k="$1" v="$2" tmp
  tmp="$(mktemp)"
  [ -f "$CONF" ] && awk -F= -v k="$k" '$1!=k' "$CONF" > "$tmp"
  printf '%s=%s\n' "$k" "$v" >> "$tmp"
  mv "$tmp" "$CONF"
}

ensure_conf() {
  [ -f "$CONF" ] && return 0
  {
    echo "# phone-remote-control 配置（由 phone.sh 自动生成）"
    echo "# MODE: auto | usb | wifi | tailscale"
    echo "MODE=auto"
    echo "# WIFI_ADDR: 无线调试的 IP:端口（pair 成功后自动写入）"
    echo "# USB_SERIAL: 多台 USB 设备时指定"
    echo "# TS_HOST: Tailscale 中手机的主机名（tailscale status 可见）"
  } > "$CONF"
  chmod 600 "$CONF"
}
ensure_conf

PORT="${ADB_PORT:-$(conf_get ADB_PORT)}"; [ -n "$PORT" ] || PORT="$PORT_DEFAULT"
SERIAL="${PHONE_SERIAL:-$(conf_get PHONE_SERIAL)}"
WIFI_ADDR="${PHONE_WIFI_ADDR:-$(conf_get WIFI_ADDR)}"
TS_HOST="${PHONE_HOST:-$(conf_get TS_HOST)}"
PHONE_IP_FROM_ENV="${PHONE_IP:-}"
PHONE_IP="${PHONE_IP_FROM_ENV:-$(conf_get PHONE_IP)}"

TARGET=""   # 当前用于 adb -s 的目标，由 pick_target 决定

# ---------------------------------------------------------------- 设备发现
# 输出所有 adb 可见设备：serial<TAB>state<TAB>kind
list_devices() {
  "$ADB" devices 2>/dev/null | awk 'NR>1 && NF>=2 {
    kind = ($1 ~ /:[0-9]+$/) ? "tcp" : "usb"
    print $1 "\t" $2 "\t" kind
  }'
}

# 从 adb mDNS 服务中找无线调试端口（Android 11+ 自动发布）
mdns_targets() {
  "$ADB" mdns services 2>/dev/null | awk '
    /_adb-tls-connect\._tcp/ || /_adb\._tcp/ {
      # 服务名形如 adb-XXXXXX-abcdef._adb-tls-connect._tcp  addr 形如 192.168.1.5:37001
      for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-fA-F:.]+:[0-9]+$/) { print $i; exit }
    }'
}

# 按优先级尝试，第一个成功的写入 TARGET
pick_target() {
  local want="${PHONE_MODE:-$MODE}"
  local d dev st kind wifi

  # 0) 用户显式指定
  if [ -n "$SERIAL" ]; then
    TARGET="$SERIAL"
    return 0
  fi

  case "$want" in
    usb)
      dev="$(list_devices | awk -F'\t' '$3=="usb" && $2=="device"{print $1; exit}')"
      [ -n "$dev" ] && { TARGET="$dev"; return 0; }
      return 1 ;;
    wifi)
      # 先尝试缓存的无线调试地址
      if [ -n "$WIFI_ADDR" ]; then
        _timeout 10 "$ADB" connect "$WIFI_ADDR" >/dev/null 2>&1
        sleep 1
        list_devices | awk -F'\t' -v t="$WIFI_ADDR" '$1==t && $2=="device"{f=1} END{exit f?0:1}' \
          && { TARGET="$WIFI_ADDR"; return 0; }
      fi
      wifi="$(mdns_targets)"
      if [ -n "$wifi" ]; then
        _timeout 10 "$ADB" connect "$wifi" >/dev/null 2>&1
        sleep 1
        list_devices | awk -F'\t' -v t="$wifi" '$1==t && $2=="device"{f=1} END{exit f?0:1}' \
          && { TARGET="$wifi"; conf_set WIFI_ADDR "$wifi"; return 0; }
      fi
      return 1 ;;
    tailscale)
      [ -n "$TS" ] || return 1
      if [ -z "$PHONE_IP" ] && [ -n "$TS_HOST" ]; then
        PHONE_IP="$("$TS" ip -4 "$TS_HOST" 2>/dev/null | awk 'NF && $1 ~ /^100\./{print $1; exit}')"
      fi
      [ -n "$PHONE_IP" ] || return 1
      TARGET="${PHONE_IP}:${PORT}"
      _timeout 10 "$ADB" connect "$TARGET" >/dev/null 2>&1
      sleep 1
      list_devices | awk -F'\t' -v t="$TARGET" '$1==t && $2=="device"{f=1} END{exit f?0:1}' \
        && { conf_set PHONE_IP "$PHONE_IP"; return 0; }
      return 1 ;;
    auto)
      # 1) 已经连着的直接复用（USB 优先，其次 TCP）
      dev="$(list_devices | awk -F'\t' '$2=="device" && $3=="usb"{print $1; exit}')"
      [ -z "$dev" ] && dev="$(list_devices | awk -F'\t' '$2=="device"{print $1; exit}')"
      [ -n "$dev" ] && { TARGET="$dev"; return 0; }
      # 2) 依次尝试三种方式
      #    函数在同一 shell 中执行，可直接写 TARGET
      MODE=usb;       pick_target && return 0
      MODE=wifi;      pick_target && return 0
      MODE=tailscale; pick_target && return 0
      MODE=auto
      return 1 ;;
    *) echo "未知 PHONE_MODE: $want（可选 auto|usb|wifi|tailscale）" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------- 连接管理
is_connected() {
  [ -n "$TARGET" ] || return 1
  "$ADB" devices 2>/dev/null | awk -v t="$TARGET" '$1==t && $2=="device"{f=1} END{exit f?0:1}'
}

conn_state() {
  [ -n "$TARGET" ] || return 1
  "$ADB" devices 2>/dev/null | awk -v t="$TARGET" '$1==t{print $2; exit}'
}

# 清理同机冗余连接（否则 scrcpy 报 Server connection failed）
clean_dupes() {
  local keep="$TARGET" sn c csn
  sn="$(adbt -s "$keep" shell getprop ro.serialno 2>/dev/null | tr -d '\r')"
  [ -n "$sn" ] || return 0
  for c in $("$ADB" devices | awk '$1 ~ /:[0-9]+$/ {print $1}'); do
    [ "$c" = "$keep" ] && continue
    csn="$(adbt -s "$c" shell getprop ro.serialno 2>/dev/null | tr -d '\r')"
    [ "$csn" = "$sn" ] && { echo "  · 清理同机冗余连接: $c"; "$ADB" disconnect "$c" >/dev/null 2>&1; }
  done
}

print_connect_error() {
  local st
  st="$(conn_state)"
  echo "✗ 未找到可用的手机连接" >&2
  [ -n "$st" ] && echo "  adb 状态: ${st}" >&2
  echo "  排查顺序：" >&2
  echo "   1) phone.sh doctor             # 一键分层诊断" >&2
  echo "   2) phone.sh setup              # 图文引导第一次接入" >&2
  if [ "$MODE" = "usb" ]; then
    echo "   3) 数据线插好，手机通知栏选「传输文件」，并在手机上允许 USB 调试" >&2
  elif [ "$MODE" = "wifi" ]; then
    echo "   3) 开发者选项 →「无线调试」保持打开，且手机与电脑在同一 Wi-Fi" >&2
  elif [ "$MODE" = "tailscale" ]; then
    echo "   3) 手机和电脑都已登录同一 Tailscale 账号；重启后需插一次线跑 phone.sh openport" >&2
  else
    echo "   3) 三种方式都试过了：USB 线 / 无线调试 / Tailscale，详见 docs/setup/" >&2
  fi
}

ensure() {
  if is_connected; then clean_dupes; return 0; fi
  TARGET=""
  if pick_target; then clean_dupes; return 0; fi
  print_connect_error
  return 1
}

need() { ensure || exit 1; }

# P：吞掉 stderr（适合取值）；PR：合并 stderr（适合需要报错的操作）
P()  { adbt -s "$TARGET" "$@" 2>/dev/null | tr -d '\r'; }
PR() { adbt -s "$TARGET" "$@" 2>&1 | tr -d '\r'; }

# ---------------------------------------------------------------- 设备状态
dev_screen()  { P shell "dumpsys power" 2>/dev/null | sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -1; }
dev_locked()  { P shell "dumpsys window" 2>/dev/null | sed -n 's/.*mDreamingLockscreen=\([A-Za-z]*\).*/\1/p' | head -1; }
dev_focus()   { P shell "dumpsys window" 2>/dev/null | sed -n 's/.*mCurrentFocus=//p' | head -1; }

ui_xml() {
  # uiautomator 在界面持续动画时（秒表、加载圈、视频）会报
  # "ERROR: could not get idle state." 并拿不到 XML。
  # 策略：先 compressed，失败则不带 compressed，再失败则等一小会儿重试。
  # 同时强制 UI watchdog 放宽空闲判定，减少这类假失败。
  local xml attempt
  for attempt in 1 2 3; do
    case "$attempt" in
      1) xml="$(P shell "uiautomator dump --compressed /sdcard/.phone_ui.xml >/dev/null 2>&1; cat /sdcard/.phone_ui.xml 2>/dev/null; rm -f /sdcard/.phone_ui.xml")" ;;
      2) # 换非 compressed 写法（少数 ROM 上 compressed 参数有兼容问题）
         xml="$(P shell "uiautomator dump /sdcard/.phone_ui.xml >/dev/null 2>&1; cat /sdcard/.phone_ui.xml 2>/dev/null; rm -f /sdcard/.phone_ui.xml")" ;;
      *) # 关键兜底：某些界面（秒表、时钟秒针）永远不进入 idle，dump 一定失败。
         # 用 screencap 把当前帧"冻住"再读 —— 界面静止了就能拿到 idle 状态。
         # 注意：这一步会让屏幕短暂静止，不影响真实操作，也不需要额外权限。
         P shell "input keyevent KEYCODE_WAKEUP" >/dev/null 2>&1
         sleep 0.3
         xml="$(P shell "uiautomator dump --compressed /sdcard/.phone_ui.xml >/dev/null 2>&1; cat /sdcard/.phone_ui.xml 2>/dev/null; rm -f /sdcard/.phone_ui.xml")"
         if [ -z "$xml" ]; then
           # 最后再试：扩大 dump 等待窗口（部分 ROM 支持 timeout 参数）
           xml="$(P shell "uiautomator dump --compressed --windows /sdcard/.phone_ui.xml >/dev/null 2>&1; cat /sdcard/.phone_ui.xml 2>/dev/null; rm -f /sdcard/.phone_ui.xml")"
         fi ;;
    esac
    case "$xml" in *"<hierarchy"*) printf '%s\n' "$xml"; return 0 ;; esac
    [ "$attempt" -lt 3 ] && sleep 0.6
  done
  # 全部失败：给出可操作的诊断，而不是让下游报一个莫名其妙的解析错误
  echo "✗ 无法读取界面（uiautomator 拿不到空闲状态）" >&2
  echo "  常见原因：界面正在持续动画（秒表/视频/加载圈）、屏幕锁着、或该 App 禁止读取。" >&2
  echo "  建议：先 phone.sh shot 看一眼屏幕实际状态，或稍等后重试。" >&2
  return 1
}

parse_ui() {
  local mode="${1:-tsv}"; shift || true
  if command -v python3 >/dev/null 2>&1 && [ -f "$UI_PARSE" ]; then
    python3 "$UI_PARSE" "$mode" "$@"
  else
    case "$mode" in
      text) tr '>' '\n' | awk -F'text="' 'NF>1{split($2,a,"\""); if(a[1]!="") print a[1]}' ;;
      *) echo "✗ 需要 python3 才能解析界面节点（nodes / tap-text / wait-text）" >&2; return 1 ;;
    esac
  fi
}

# ---------------------------------------------------------------- 帮助
cmd_help() {
  cat <<'EOF'
phone.sh — 通用 Android 手机控制（给人和 AI agent 都能用）

连接
  setup                  首次接入向导：检测环境 + 按平台给出下一步
  pair [IP:端口 配对码]   无线调试配对（不传参数则自动发现并提示）
  doctor                 分层诊断：设备 → 链路 → 端口 → adb → 界面（连不上先跑它）
  status                 一次看全：工具、模式、设备、屏幕、前台
  devices                列出所有可见设备（USB / 无线 / 穿透）
  connect                建立/确保连接（自动清理同机冗余连接）
  disconnect [--all]     断开 TCP 连接（USB 不受影响）
  screen                 屏幕亮灭 / 锁屏 / 前台应用
  wake                   唤醒屏幕
  openport               [需 USB] 开启 TCP 5555（Tailscale 模式重启后必做）
  recover                重启后恢复向导

读界面
  shot [--small] [文件]   截图；--small 输出宽 800 的 JPEG（快、省流量）
  nodes [--json] [--all]  界面节点：text / desc / id / class / bounds / flags
  find <文本>             查找包含该文本的节点
  ui                      当前界面所有文本
  current                 当前前台窗口

操作（都会自动确保连接）
  tap-text <文本> [--exact]   按文字找到控件并点击（首选，替代盲点坐标）
  tap-id <id片段>             按 resource-id 点击
  wait-text <文本> [秒]       轮询等待文字出现（默认 20s）—— 用来替代死 sleep
  scroll-to <文本> [次数]     向上滚动直到找到文字（默认 6 次）
  tap X Y                     点击坐标（拿到 bounds 后再用）
  swipe X1 Y1 X2 Y2 [ms]      滑动（默认 300ms）
  key <KEYCODE>               按键（HOME / BACK / ENTER / POWER / 26 …）
  text <内容>                 输入文本（ASCII 直输；中文需 ADBKeyboard）
  open <url>                  用系统意图打开 URL
  app <包名...>               启动应用
  apps [关键词]               列出已安装应用

其他
  shell <命令...>         任意 shell 命令
  logcat [行数]           最近日志（默认 200 行）
  record [秒] [文件]      录屏并拉回电脑（默认 10s，单段上限 3 分钟）
  push <本地> <手机路径>
  pull <手机路径> <本地>
  install <apk>           安装 APK
  mirror [--bg] [参数]    投屏（需要 scrcpy）
  reboot                  重启（会断开连接，需 PHONE_ALLOW_REBOOT=1）

连接方式（PHONE_MODE，默认 auto）
  usb        USB 数据线          最稳，首次接入首选
  wifi       无线调试（Android 11+）零安装，同一 Wi-Fi 即可   ← 推荐
  tailscale  Tailscale 异地穿透  在外网控制家里的手机
  auto       依次尝试 usb → wifi → tailscale

示例
  phone.sh setup                    # 第一次用先跑这个
  phone.sh doctor                   # 连不上先跑这个
  phone.sh app com.android.settings
  phone.sh wait-text "WLAN" 10
  phone.sh tap-text "WLAN"
  phone.sh shot --small ~/Desktop/phone.jpg
  PHONE_MODE=wifi phone.sh screen
EOF
}

# ---------------------------------------------------------------- 状态类
cmd_status() {
  echo "=== 工具 ==="
  echo "  adb      : $ADB"
  echo "  python3  : $(command -v python3 || echo '（缺失：界面解析不可用）')"
  echo "  scrcpy   : ${SCRCPY:-（未安装，投屏不可用）}"
  echo "  tailscale: ${TS:-（未安装，仅影响 tailscale 模式）}"
  echo "  配置     : $CONF"
  echo "  模式     : $MODE"
  echo "=== 设备 ==="
  local n=0
  while IFS=$'\t' read -r s st k; do
    [ -n "$s" ] || continue
    n=$((n+1))
    printf '  %-24s %-12s %s\n' "$s" "$st" "$k"
  done < <(list_devices)
  [ "$n" = 0 ] && echo "  （无设备）"
  if ensure 2>/dev/null; then
    echo "=== 当前操作目标: ${TARGET} ==="
    echo "  型号/系统  : $(P shell 'getprop ro.product.model') / Android $(P shell 'getprop ro.build.version.release')"
    echo "  屏幕/锁屏  : $(dev_screen) / $(dev_locked)"
    echo "  前台       : $(dev_focus)"
  fi
}

cmd_devices() {
  printf '%-28s %-12s %-6s %s\n' SERIAL STATE TYPE MODEL
  while IFS=$'\t' read -r s st k; do
    [ -n "$s" ] || continue
    local m=""
    [ "$st" = "device" ] && m="$("$ADB" -s "$s" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
    printf '%-28s %-12s %-6s %s\n' "$s" "$st" "$k" "$m"
  done < <(list_devices)
}

cmd_ip() {
  [ -n "$PHONE_IP" ] || {
    if [ -n "$TS" ] && [ -n "$TS_HOST" ]; then
      PHONE_IP="$("$TS" ip -4 "$TS_HOST" 2>/dev/null | awk 'NF && $1 ~ /^100\./{print $1; exit}')"
    fi
  }
  echo "${PHONE_IP:-}"
}

cmd_connect() { ensure || exit 1; echo "✓ 已连接 ${TARGET}"; }

cmd_disconnect() {
  local all=0; [ "${1:-}" = "--all" ] && all=1
  local c found=0
  for c in $("$ADB" devices | awk '$1 ~ /:[0-9]+$/ {print $1}'); do
    if [ "$all" = 1 ] || [ -z "$TARGET" ] || [ "$c" = "$TARGET" ]; then
      echo "  · 断开 ${c}"; "$ADB" disconnect "$c" >/dev/null 2>&1; found=1
    fi
  done
  if [ "$all" = 1 ]; then echo "✓ 已断开所有 TCP 连接（USB 不受影响）"
  elif [ "$found" = 1 ]; then echo "✓ 已断开 TCP 连接（USB 不受影响）"
  else echo "（没有可断开的 TCP 连接）"; fi
}

# ---------------------------------------------------------------- 无线调试配对
cmd_pair() {
  local addr="${1:-}" code="${2:-}"
  # 自动从 mDNS 发现配对端口（_adb-tls-pairing._tcp）
  if [ -z "$addr" ]; then
    local pairing
    pairing="$("$ADB" mdns services 2>/dev/null | awk '
      /_adb-tls-pairing\._tcp/ {
        for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-fA-F:.]+:[0-9]+$/) { print $i; exit }
      }')"
    if [ -z "$pairing" ]; then
      echo "✗ 未自动发现配对服务。请确认：" >&2
      echo "  1) 手机开发者选项 →「无线调试」已打开" >&2
      echo "  2) 手机和电脑在同一 Wi-Fi" >&2
      echo "  3) 在手机上点「使用配对码配对设备」，保持那个弹窗不要关" >&2
      echo "  然后重跑；或手动传入：phone.sh pair <IP:端口> <配对码>" >&2
      return 1
    fi
    addr="$pairing"
  fi
  if [ -z "$code" ]; then
    echo "→ 已发现配对端口 ${addr}" >&2
    printf '请输入手机上显示的 6 位配对码: ' >&2
    read -r code
  fi
  local out
  out="$(_timeout 30 "$ADB" pair "$addr" "$code" 2>&1)"
  printf '%s\n' "$out" | sed 's/^/    /'
  case "$out" in
    *"Successfully paired"*) ;;
    *) echo "✗ 配对失败。常见原因：配对码过期（重新在手机上点一次）/ 端口已变 / 不在同一网络" >&2; return 1 ;;
  esac
  echo "→ 配对成功，正在建立连接…"
  sleep 2
  local wifi; wifi="$(mdns_targets)"
  if [ -n "$wifi" ]; then
    _timeout 10 "$ADB" connect "$wifi" >/dev/null 2>&1
    sleep 1
    if list_devices | awk -F'\t' -v t="$wifi" '$1==t && $2=="device"{f=1} END{exit f?0:1}'; then
      conf_set WIFI_ADDR "$wifi"
      echo "✓ 已连接 ${wifi}（已记住）"
      return 0
    fi
  fi
  echo "⚠ 配对成功但未能自动连接。请在手机上重新打开一次「无线调试」，再跑 phone.sh connect" >&2
  return 1
}

# ---------------------------------------------------------------- 首次接入向导
cmd_setup() {
  local check_only=0
  [ "${1:-}" = "--check" ] && check_only=1

  echo "═══════════ phone-remote-control 接入向导 ═══════════"
  echo
  echo "【1/4】本机环境"
  echo "  adb      : ${ADB:-缺失}"
  [ -z "$SCRCPY" ] && echo "  scrcpy   : 未安装（可选，只影响投屏）"
  [ -n "$SCRCPY" ] && echo "  scrcpy   : $SCRCPY"
  local py; py="$(command -v python3 || true)"
  if [ -n "$py" ]; then echo "  python3  : $py"
  else echo "  python3  : ✗ 缺失 —— nodes / tap-text / wait-text 将不可用（强烈建议安装）"; fi

  echo
  echo "【2/4】已连接设备"
  local found=0
  while IFS=$'\t' read -r s st k; do
    [ -n "$s" ] || continue
    found=1
    printf '  %-24s %s\n' "$s" "$st"
  done < <(list_devices)
  [ "$found" = 0 ] && echo "  （无）"

  echo
  echo "【3/4】接口与链路"
  local usb_dev tcp_dev wifi_ok=0
  usb_dev="$(list_devices | awk -F'\t' '$3=="usb" && $2=="device"{print $1; exit}')"
  tcp_dev="$(list_devices | awk -F'\t' '$3=="tcp" && $2=="device"{print $1; exit}')"
  [ -n "$usb_dev" ]  && echo "  ✓ USB 设备可用: ${usb_dev}"
  [ -n "$tcp_dev" ]  && echo "  ✓ 网络设备可用: ${tcp_dev}"
  mdns_targets | awk 'NF{getline; print "  ✓ 无线调试服务已发现"}' | head -1
  [ -n "$TS" ] && echo "  ✓ Tailscale 已安装（可用于异地控制）" || echo "  · Tailscale 未安装（仅异地控制需要）"

  echo
  echo "【4/4】结论"
  if ensure 2>/dev/null; then
    echo "  ✅ 可以直接用了：$(P shell 'getprop ro.product.model')"
    echo "     试试：phone.sh screen && phone.sh shot --small /tmp/a.jpg"
    return 0
  fi

  cat <<'EOF'

  ❌ 还没连上手机。请按你的场景选一种：

  ┌─ 方式 A：无线调试（推荐，不用数据线、不用装 App）──────────────
  │ 手机设置 → 关于手机 → 连点「版本号」7 次 → 打开开发者选项
  │ 开发者选项 → 打开「无线调试」
  │ 手机和电脑连同一个 Wi-Fi
  │ 在手机上点「使用配对码配对设备」，记下 6 位配对码
  │ 然后运行：  phone.sh pair
  └─────────────────────────────────────────────────────────

  ┌─ 方式 B：USB 数据线（最稳，第一次接入也推荐）────────────────
  │ 1. 用「能传数据」的线连电脑（不是只充电的线）
  │ 2. 手机通知栏把 USB 用途改成「传输文件 / MTP」
  │ 3. 开发者选项 → 打开「USB 调试」
  │ 4. 手机弹窗「允许 USB 调试吗」→ 勾选「一律允许」→ 允许
  └─────────────────────────────────────────────────────────

  ┌─ 方式 C：Tailscale 异地控制（在外网控制家里的手机）──────────
  │ 先在方式 B 下跑一次：phone.sh openport
  │ 手机和电脑都装 Tailscale 并登录同一账号
  │ phone.sh shell getprop ro.serialno   # 确认链路
  │ 详细介绍见 docs/setup/tailscale.md
  └─────────────────────────────────────────────────────────

EOF
  return 1
}

# ---------------------------------------------------------------- 诊断
cmd_doctor() {
  local issues=0 dev st kind
  echo "═══ 手机连接诊断 v${VERSION} $(date '+%H:%M:%S') ═══"
  echo "【0】工具与模式"
  echo "  adb      : $ADB"
  echo "  scrcpy   : ${SCRCPY:-（未安装，投屏不可用）}"
  echo "  tailscale: ${TS:-（未安装，仅影响 tailscale 模式）}"
  echo "  模式     : $MODE"
  echo "  配置     : $CONF"

  echo "【1】adb devices"
  local n=0
  while IFS=$'\t' read -r dev st kind; do
    [ -n "$dev" ] || continue
    n=$((n+1))
    printf '  %-24s %-13s %s\n' "$dev" "$st" "$kind"
    case "$st" in
      device) ;;
      offline)      echo "    ⚠ 连接假死 → phone.sh disconnect --all 然后重连"; issues=$((issues+1)) ;;
      unauthorized) echo "    ⚠ 未授权 → 看手机屏幕，勾选「一律允许」并点允许"; issues=$((issues+1)) ;;
      *)            echo "    ⚠ 状态异常: $st"; issues=$((issues+1)) ;;
    esac
  done < <(list_devices)
  [ "$n" = 0 ] && echo "  （无设备）"

  echo "【2】无线调试服务（mDNS）"
  local m; m="$("$ADB" mdns services 2>/dev/null | grep -E '_adb' | head -5)"
  if [ -n "$m" ]; then printf '%s\n' "$m" | sed 's/^/  /'
  else
    echo "  （未发现 —— 无线调试未开启，或当前网络屏蔽了组播）"
  fi

  echo "【3】Tailscale"
  if [ -n "$TS" ]; then
    local peer
    # 只取主机名与状态，刻意不打 tailnet 账号与内网 IP（避免日志泄露隐私）
    peer="$("$TS" status 2>/dev/null | awk 'tolower($0) ~ /android/ {
      host = $2; st = "active"
      if (tolower($0) ~ /offline/) st = "offline"
      print host "\t" st; exit }')"
    if [ -n "$peer" ]; then
      echo "  主机名: $(printf '%s' "$peer" | cut -f1)  状态: $(printf '%s' "$peer" | cut -f2)"
      case "$peer" in *offline*) echo "  ✗ 节点 offline（手机 Tailscale 未连上？）"; issues=$((issues+1)) ;; esac
    else
      echo "  · tailnet 中未见 Android 节点（异地控制需要）"
    fi
  fi

  echo "【4】连接与操作面"
  TARGET=""
  if pick_target; then
    echo "  ✓ 目标: ${TARGET}"
    echo "  · 型号   : $(P shell 'getprop ro.product.model')"
    echo "  · Android: $(P shell 'getprop ro.build.version.release')"
    echo "  · 屏幕   : $(dev_screen) / 锁屏: $(dev_locked)"
    echo "  · 前台   : $(dev_focus)"
    # 界面解析能力自检：这是最容易「看起来连上了但 agent 用不了」的坑
    if command -v python3 >/dev/null 2>&1; then
      local cnt
      cnt="$(ui_xml 2>/dev/null | parse_ui tsv 2>/dev/null | wc -l | tr -d ' ')"
      if [ "${cnt:-0}" -gt 0 ]; then
        echo "  ✓ 界面解析正常（${cnt} 个节点）"
      else
        echo "  ✗ 界面解析失败：屏幕可能熄灭/锁屏，试 phone.sh wake"; issues=$((issues+1))
      fi
    else
      echo "  ⚠ 无 python3，tap-text / nodes 不可用"; issues=$((issues+1))
    fi
  else
    echo "  ✗ 无可用连接"
    issues=$((issues+1))
  fi

  echo "════════════════════"
  if [ "$issues" -eq 0 ]; then
    echo "✅ 一切正常，可以直接操作"
  else
    echo "⚠ ${issues} 项异常。多数情况直接跑 phone.sh setup 会给出下一步"
  fi
  return "$issues"
}

# ---------------------------------------------------------------- 端口/恢复
cmd_openport() {
  local usb cnt
  usb="$("$ADB" devices | awk 'NR>1 && $2=="device" && $1 !~ /:/ {print $1}')"
  cnt="$(printf '%s\n' "$usb" | awk 'NF' | wc -l | tr -d ' ')"
  if [ -z "$usb" ]; then
    echo "✗ 未发现 USB 设备。请用数据线连接手机，并允许 USB 调试。" >&2
    "$ADB" devices -l 2>/dev/null | sed 's/^/    /' >&2
    return 1
  fi
  [ "$cnt" -gt 1 ] && { echo "✗ 发现多台 USB 设备，请只保留目标手机：" >&2; printf '%s\n' "$usb" | sed 's/^/    /' >&2; return 1; }
  echo "→ USB 设备 ${usb}：开启 TCP 端口 ${PORT}"
  "$ADB" -s "$usb" tcpip "$PORT" 2>&1 | sed 's/^/    /'
  sleep 3
  local ip; ip="$(cmd_ip)"
  [ -n "$ip" ] && { conf_set PHONE_IP "$ip"; PHONE_IP="$ip"; echo "✓ 手机 Tailscale IP: ${ip}"; } \
               || echo "⚠ 未在 tailnet 找到手机（tailscale 模式需要手机已登录）"
  echo "→ 下一步：拔掉线，运行  PHONE_MODE=tailscale phone.sh connect"
}

cmd_recover() {
  if ensure 2>/dev/null; then echo "✓ 已有可用连接：${TARGET}（无需恢复）"; return 0; fi
  echo "· 未找到可用连接（手机重启后 5555 / 无线调试都会失效，这是系统行为）"
  local usb
  usb="$("$ADB" devices | awk 'NR>1 && $2=="device" && $1 !~ /:/ {print $1}')"
  if [ -z "$usb" ]; then
    echo "需要先插一次 USB 数据线，然后重跑: phone.sh recover" >&2
    echo "或者用无线调试：在手机上重开「无线调试」后跑 phone.sh pair" >&2
    "$ADB" devices -l 2>/dev/null | sed 's/^/    /'
    return 1
  fi
  cmd_openport
}

cmd_screen() {
  need
  local w l f
  w="$(dev_screen)"; l="$(dev_locked)"; f="$(dev_focus)"
  echo "屏幕: ${w:-unknown} | 锁屏: ${l:-unknown} | 前台: ${f:-unknown}"
  case "$w" in Asleep|Dozing) echo "提示：屏幕未亮，先执行 phone.sh wake";; esac
  case "$l" in true) echo "提示：当前锁屏，点击不会生效；需先在手机上解锁";; esac
}

cmd_current() { need; dev_focus; }
cmd_wake() { need; P shell "input keyevent KEYCODE_WAKEUP" >/dev/null; sleep 1; cmd_screen; }

# ---------------------------------------------------------------- 截图
cmd_shot() {
  need
  local small=0 out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --small|--jpeg) small=1 ;;
      *) out="$1" ;;
    esac
    shift
  done
  [ -n "$out" ] || out="/tmp/phone-shot-$(date +%Y%m%d-%H%M%S).png"
  adbt -s "$TARGET" exec-out screencap -p > "$out" 2>/dev/null
  if [ ! -s "$out" ]; then rm -f "$out"; echo "✗ 截图失败（屏幕熄灭或连接中断）" >&2; return 1; fi
  if [ "$small" = 1 ]; then
    # 修复旧版 bug：传入 x.jpg 曾生成 x.jpg.jpg
    local base="${out%.*}" jpg="${out%.*}.jpg"
    if command -v sips >/dev/null 2>&1; then
      sips -Z 800 -s format jpeg -s formatOptions 75 "$out" --out "$jpg" >/dev/null 2>&1 \
        && { [ "$out" != "$jpg" ] && rm -f "$out"; out="$jpg"; }
    elif command -v magick >/dev/null 2>&1; then
      magick "$out" -resize 800x800\> -quality 75 "$jpg" >/dev/null 2>&1 \
        && { [ "$out" != "$jpg" ] && rm -f "$out"; out="$jpg"; }
    fi
    : "$base"
  fi
  echo "$out"
}

# ---------------------------------------------------------------- 读界面
cmd_ui() {
  need
  local xml
  xml="$(ui_xml)" || exit 1
  printf '%s' "$xml" | parse_ui text
}

cmd_nodes() {
  need
  local mode=tsv flag_all=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) mode=json ;;
      --all) flag_all=1 ;;
      *) break ;;
    esac
    shift
  done
  if [ "$mode" = "json" ]; then
    ui_xml | parse_ui json || exit 1
  elif [ "$flag_all" = 1 ]; then
    ui_xml | parse_ui tsv --all || exit 1
  else
    ui_xml | parse_ui tsv || exit 1
  fi
}

cmd_find() {
  need
  local needle="${1:-}"
  [ -n "$needle" ] || { echo "用法: phone.sh find <文本>" >&2; return 2; }
  local out; out="$(ui_xml | parse_ui find-text "$needle")" || { echo "✗ 未找到「${needle}」" >&2; return 1; }
  printf '%s\n' "$out"
}

# 通用：选出节点。输出两行：第 1 行 "x y"，第 2 行节点摘要。
pick_node() {
  local mode="$1" needle="$2" exact="${3:-0}" ex=""
  [ "$exact" = 1 ] && ex="--exact"
  ui_xml | parse_ui "$mode" "$needle" $ex
}
pick_xy()      { printf '%s\n' "$1" | awk 'NR==1{print $1, $2}'; }
pick_summary() { printf '%s\n' "$1" | awk 'NR==2{print}'; }

cmd_tap_text() {
  need
  local needle="${1:-}"; [ -n "$needle" ] || { echo "用法: phone.sh tap-text <文本> [--exact]" >&2; return 2; }
  local exact=0; [ "${2:-}" = "--exact" ] && exact=1
  local row xy x y
  row="$(pick_node pick-text "$needle" "$exact")" || { echo "✗ 界面上未找到「${needle}」" >&2; return 1; }
  xy="$(pick_xy "$row")"; x="${xy% *}"; y="${xy#* }"
  P shell "input tap $x $y" >/dev/null || { echo "✗ 点击失败" >&2; return 1; }
  echo "✓ 点击「${needle}」@ (${x},${y})"; pick_summary "$row" | sed 's/^/  /'
}

cmd_tap_id() {
  need
  local needle="${1:-}"; [ -n "$needle" ] || { echo "用法: phone.sh tap-id <resource-id 片段>" >&2; return 2; }
  local row xy x y
  row="$(pick_node pick-id "$needle")" || { echo "✗ 未找到 resource-id 含「${needle}」的节点" >&2; return 1; }
  xy="$(pick_xy "$row")"; x="${xy% *}"; y="${xy#* }"
  P shell "input tap $x $y" >/dev/null || { echo "✗ 点击失败" >&2; return 1; }
  echo "✓ 点击 id 含「${needle}」@ (${x},${y})"; pick_summary "$row" | sed 's/^/  /'
}

cmd_wait_text() {
  need
  local needle="${1:-}"; [ -n "$needle" ] || { echo "用法: phone.sh wait-text <文本> [超时秒=20]" >&2; return 2; }
  local timeout="${2:-20}" t0 now row
  t0=$(date +%s)
  while :; do
    row="$(pick_node pick-text "$needle" 0)" && { echo "✓ 已出现「${needle}」"; pick_summary "$row" | sed 's/^/  /'; return 0; }
    now=$(date +%s)
    [ $((now - t0)) -ge "$timeout" ] && { echo "✗ ${timeout}s 内未出现「${needle}」" >&2; return 1; }
    sleep 1
  done
}

cmd_scroll_to() {
  need
  local needle="${1:-}"; [ -n "$needle" ] || { echo "用法: phone.sh scroll-to <文本> [最多滚动次数=6]" >&2; return 2; }
  local max="${2:-6}" i row
  # 用屏幕实际尺寸算滑动距离，而不是写死 540/1800
  local size w h
  size="$(P shell 'wm size' 2>/dev/null | awk -F: '/Physical size/{gsub(/ /,"",$2); print $2; exit}')"
  w="${size%x*}"; h="${size#*x}"
  case "$w" in ''|*[!0-9]*) w=1080 ;; esac
  case "$h" in ''|*[!0-9]*) h=1920 ;; esac
  local x=$((w / 2)) y1=$((h * 3 / 4)) y2=$((h / 4))

  row="$(pick_node pick-text "$needle" 0)" && { echo "✓ 已在当前屏"; pick_summary "$row" | sed 's/^/  /'; return 0; }
  for i in $(seq 1 "$max"); do
    P shell "input swipe $x $y1 $x $y2 400" >/dev/null
    sleep 1
    row="$(pick_node pick-text "$needle" 0)" && { echo "✓ 第 ${i} 次滚动后找到"; pick_summary "$row" | sed 's/^/  /'; return 0; }
  done
  echo "✗ 滚动 ${max} 次仍未找到「${needle}」" >&2
  return 1
}

cmd_tap()   { need; P shell "input tap $1 $2" >/dev/null || { echo "✗ 点击失败" >&2; return 1; }; echo "✓ tap $1 $2"; }
cmd_swipe() { need; P shell "input swipe $1 $2 $3 $4 ${5:-300}" >/dev/null || { echo "✗ 滑动失败" >&2; return 1; }; echo "✓ swipe $1 $2 -> $3 $4"; }
cmd_key()   { need; P shell "input keyevent $1" >/dev/null || { echo "✗ 按键失败" >&2; return 1; }; echo "✓ keyevent $1"; }

# ---------------------------------------------------------------- 输入
cmd_text() {
  need
  local s="$*"
  [ -n "$s" ] || { echo "用法: phone.sh text <内容>" >&2; return 2; }
  local nonascii
  nonascii="$(printf '%s' "$s" | LC_ALL=C tr -d '\040-\176' | wc -c | tr -d ' ')"
  if [ "$nonascii" != "0" ]; then
    # 非 ASCII（中文/emoji）：input text 不支持，需要 ADBKeyboard
    if P shell "ime list -s" 2>/dev/null | grep -qiE 'adbkeyboard|AdbIME'; then
      local b64
      b64="$(printf '%s' "$s" | base64 | tr -d '\n')"
      P shell "am broadcast -a ADB_INPUT_B64 --es msg '$b64'" >/dev/null 2>&1 \
        && { echo "✓ 已通过 ADBKeyboard 输入（含非 ASCII）"; return 0; }
      echo "✗ ADBKeyboard 广播失败" >&2
      return 1
    fi
    echo "✗ 中文/emoji 需要 ADBKeyboard 输入法（系统 input text 只支持 ASCII）" >&2
    echo "  安装：https://github.com/senzhk/ADBKeyBoard/releases" >&2
    echo "  然后：手机设置 → 语言与输入法 → 当前输入法 → 选 ADBKeyboard" >&2
    echo "  提示：更快的方式是让 agent 直接操作界面（tap-text），不必输入中文" >&2
    return 1
  fi
  # ASCII 直输：先做 shell 转义，避免空格和引号被吃
  P shell "input text '$(printf '%s' "$s" | sed "s/'/'\\\\''/g")'" >/dev/null \
    && { echo "✓ 已输入: $s"; return 0; }
  echo "✗ 输入失败" >&2
  return 1
}

cmd_open() {
  need
  local url="${1:-}"; [ -n "$url" ] || { echo "用法: phone.sh open <url>" >&2; return 2; }
  PR shell "am start -a android.intent.action.VIEW -d '$url'" | grep -qi error \
    && { echo "✗ 打开失败" >&2; return 1; }
  echo "✓ 已打开 $url"
}

cmd_app() {
  need
  [ $# -gt 0 ] || { echo "用法: phone.sh app <包名...>" >&2; return 2; }
  local pkg out rc
  for pkg in "$@"; do
    out="$(PR shell "monkey -p '$pkg' -c android.intent.category.LAUNCHER 1")"
    rc=$?
    # monkey 即使失败也常返回 0，必须看输出
    if printf '%s' "$out" | grep -qiE 'No activities found|monkey aborted|Error'; then
      echo "✗ 启动失败：$pkg" >&2
      printf '%s\n' "$out" | tail -3 | sed 's/^/    /' >&2
      echo "  提示：包名是否正确？用 phone.sh apps 关键词 查" >&2
      return 1
    fi
    [ "$rc" -ne 0 ] && { echo "✗ 启动失败：$pkg（rc=$rc）" >&2; return 1; }
    echo "✓ 已启动 $pkg"
  done
}

cmd_apps() {
  need
  local kw="${1:-}"
  P shell "pm list packages -3" | sed 's/^package://' | {
    if [ -n "$kw" ]; then grep -i -- "$kw"; else cat; fi
  }
}

# ---------------------------------------------------------------- 其他
cmd_shell() { need; PR shell "$*"; }

cmd_logcat() {
  need
  local n="${1:-200}"
  P logcat -d -t "$n" 2>/dev/null || P logcat -d 2>/dev/null | tail -n "$n"
}
cmd_logcat_clear() { need; P logcat -c >/dev/null; echo "✓ 已清空日志缓冲"; }

cmd_record() {
  need
  local secs="${1:-10}" out="${2:-}"
  case "$secs" in ''|*[!0-9]*) echo "用法: phone.sh record [秒] [文件]" >&2; return 2 ;; esac
  [ "$secs" -gt 180 ] && { echo "⚠ 单段录屏上限 180s（Android 限制），已截断" >&2; secs=180; }
  [ -n "$out" ] || out="/tmp/phone-rec-$(date +%Y%m%d-%H%M%S).mp4"
  local remote="/sdcard/.phone_rec.mp4"
  echo "→ 录制 ${secs}s…"
  P shell "screenrecord --time-limit $secs --bit-rate 8000000 '$remote'" >/dev/null 2>&1
  adbt -s "$TARGET" pull "$remote" "$out" >/dev/null 2>&1
  P shell "rm -f '$remote'" >/dev/null 2>&1
  if [ -s "$out" ]; then echo "✓ 已保存 $out"; else echo "✗ 录屏失败" >&2; return 1; fi
}

cmd_push() {
  need
  local src="${1:-}" dst="${2:-}"
  [ -n "$src" ] && [ -n "$dst" ] || { echo "用法: phone.sh push <本地> <手机路径>" >&2; return 2; }
  adbt -s "$TARGET" push "$src" "$dst" 2>&1 | tail -1
}

cmd_pull() {
  need
  local src="${1:-}" dst="${2:-}"
  [ -n "$src" ] && [ -n "$dst" ] || { echo "用法: phone.sh pull <手机路径> <本地>" >&2; return 2; }
  adbt -s "$TARGET" pull "$src" "$dst" 2>&1 | tail -1
}

cmd_install() {
  need
  local apk="${1:-}"
  [ -n "$apk" ] || { echo "用法: phone.sh install <apk>" >&2; return 2; }
  local out
  out="$(PR install -r "$apk")"
  if printf '%s' "$out" | grep -q "INSTALL_FAILED_USER_RESTRICTED"; then
    echo "✗ 被系统拦截（MIUI/部分国产 ROM）" >&2
    echo "  解决：开发者选项 → 打开「USB 安装」，再重试" >&2
    return 1
  fi
  printf '%s\n' "$out" | grep -q "Success" && { echo "✓ 安装成功"; return 0; }
  printf '%s\n' "$out" | sed 's/^/  /' >&2
  return 1
}

cmd_mirror() {
  need
  [ -n "$SCRCPY" ] || { echo "✗ 需要 scrcpy：brew install scrcpy" >&2; return 127; }
  local bg=0
  [ "${1:-}" = "--bg" ] && { bg=1; shift; }
  local args=("$@")
  [ ${#args[@]} -eq 0 ] && args=(--no-audio --stay-awake)
  if [ "$bg" = 1 ]; then
    nohup "$SCRCPY" -s "$TARGET" "${args[@]}" >/tmp/scrcpy.log 2>&1 &
    echo "✓ 投屏已在后台启动（日志 /tmp/scrcpy.log）"
  else
    "$SCRCPY" -s "$TARGET" "${args[@]}"
  fi
}

cmd_wait() {
  need
  echo -n "等待开机完成…"
  adbt -s "$TARGET" wait-for-device
  local i
  for i in $(seq 1 120); do
    [ "$(P shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && { echo " ✓"; return 0; }
    sleep 2
  done
  echo " ✗ 超时" >&2
  return 1
}

cmd_reboot() {
  need
  [ "${PHONE_ALLOW_REBOOT:-0}" = "1" ] || {
    echo "✗ reboot 会断开所有远程连接，需显式授权：" >&2
    echo "    PHONE_ALLOW_REBOOT=1 phone.sh reboot" >&2
    echo "  重启后 5555 与无线调试都会失效，需要插线或重新配对。" >&2
    return 1; }
  echo "→ 重启中（连接会断开；恢复见 phone.sh recover）"
  P reboot >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- 入口
[ $# -gt 0 ] || { cmd_help; exit 2; }

# help / version / doctor 在没有 adb 时也应该能跑：
# 一个连 adb 都没装的人，最需要看到的正是帮助和诊断信息。
case "$1" in
  help|-h|--help|version|-v|--version|doctor) ;;
  *) require_adb ;;
esac

case "$1" in
  help|-h|--help) shift; cmd_help ;;
  version|-v|--version) echo "phone-remote-control v${VERSION}" ;;

  setup)       shift; cmd_setup "$@" ;;
  pair)        shift; cmd_pair "$@" ;;
  doctor)      cmd_doctor ;;
  status)      cmd_status ;;
  devices)     cmd_devices ;;
  ip)          cmd_ip ;;
  connect)     cmd_connect ;;
  disconnect)  shift; cmd_disconnect "$@" ;;
  openport)    cmd_openport ;;
  recover)     cmd_recover ;;
  screen)      cmd_screen ;;
  current)     cmd_current ;;
  wake)        cmd_wake ;;

  shot)        shift; cmd_shot "$@" ;;
  nodes)       shift; cmd_nodes "$@" ;;
  ui)          cmd_ui ;;
  find)        shift; cmd_find "$@" ;;

  tap)         shift; cmd_tap "$@" ;;
  swipe)       shift; cmd_swipe "$@" ;;
  key)         shift; cmd_key "$@" ;;
  tap-text)    shift; cmd_tap_text "$@" ;;
  tap-id)      shift; cmd_tap_id "$@" ;;
  wait-text)   shift; cmd_wait_text "$@" ;;
  scroll-to)   shift; cmd_scroll_to "$@" ;;
  text|input-text|type) shift; cmd_text "$@" ;;
  open|url)    shift; cmd_open "$@" ;;
  app)         shift; cmd_app "$@" ;;
  apps)        shift; cmd_apps "$@" ;;

  shell)       shift; cmd_shell "$@" ;;
  logcat)      shift; cmd_logcat "$@" ;;
  logcat-clear) cmd_logcat_clear ;;
  record)      shift; cmd_record "$@" ;;
  push)        shift; cmd_push "$@" ;;
  pull)        shift; cmd_pull "$@" ;;
  install)     shift; cmd_install "$@" ;;
  mirror)      shift; cmd_mirror "$@" ;;
  wait)        cmd_wait ;;
  reboot)      cmd_reboot ;;
  *) echo "未知子命令: $1" >&2; echo; cmd_help; exit 2 ;;
esac
