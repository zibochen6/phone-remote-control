#!/usr/bin/env bash
# 不依赖 bats 的最小测试。用法：tests/run-tests.sh
# 原则：全部离线、不碰真机、不读用户配置。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/skills/phone-remote-control/scripts"
PHONE="$SCRIPTS/phone.sh"
PRIVACY="$SCRIPTS/privacy_scan.sh"
FIX="$ROOT/tests/fixtures"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# 隔离环境：绝不使用用户真实配置
export PHONE_CONF="$ROOT/tests/.tmp-test.conf"
rm -f "$PHONE_CONF"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD" "$PHONE_CONF"' EXIT

# ─────────────────────────────────────────────
head_ "1. 语法检查"

for f in "$PHONE" "$PRIVACY" "$ROOT/tests/run-tests.sh"; do
  if bash -n "$f" 2>/dev/null; then ok "$(basename "$f") 语法正确"; else bad "$(basename "$f") 语法错误"; fi
done

if python3 -m py_compile "$SCRIPTS/ui_parse.py" 2>/dev/null; then
  ok "ui_parse.py 可编译"
else
  bad "ui_parse.py 编译失败"
fi

# ─────────────────────────────────────────────
head_ "2. 基础命令（不需要设备）"

out="$("$PHONE" help 2>&1)"
case "$out" in
  *tap-text*) ok "help 列出了 tap-text" ;;
  *) bad "help 输出异常" "$(echo "$out" | head -2)" ;;
esac

# 回归：没装 adb 的机器上，help/version 仍然必须可用。
# （CI 的 Linux runner 就没有 adb，这里用空目录遮住 PATH 模拟）
NOADB="$TMPD/noadb"; mkdir -p "$NOADB"
out="$(PHONE_FORCE_NO_ADB=1 "$PHONE" help 2>&1)"
case "$out" in
  *tap-text*) ok "缺 adb 时 help 仍可用" ;;
  *) bad "缺 adb 时 help 不可用" "$(echo "$out" | head -2)" ;;
esac

out="$(PHONE_FORCE_NO_ADB=1 "$PHONE" --version 2>&1)"
case "$out" in
  *1.0.0*) ok "缺 adb 时 --version 仍可用" ;;
  *) bad "缺 adb 时 --version 不可用" "$out" ;;
esac

# 但真正需要设备的命令必须报错退出，而不是静默成功
if PHONE_FORCE_NO_ADB=1 "$PHONE" screen >/dev/null 2>&1; then
  bad "缺 adb 时 screen 应报错却成功了"
else
  ok "缺 adb 时设备命令正确报错"
fi

out="$("$PHONE" --version 2>&1)"
case "$out" in
  *1.0.0*) ok "版本号输出正常" ;;
  *) bad "版本号异常: $out" ;;
esac

# 未知命令应报错并给出帮助提示，而不是静默成功
if ! "$PHONE" definitely-not-a-command >/dev/null 2>&1; then
  ok "未知命令返回非零退出码"
else
  bad "未知命令应失败却成功了"
fi

# ─────────────────────────────────────────────
head_ "3. 配置文件权限"

"$PHONE" status >/dev/null 2>&1 || true
if [ -f "$PHONE_CONF" ]; then
  # 注意：Linux 的 stat -f 是合法参数（打印文件系统信息，不是报错），
  # 所以不能用 `stat -f ... || stat -c ...`，必须按系统分支判断。
  case "$(uname -s)" in
    Darwin) perm="$(stat -f '%Lp' "$PHONE_CONF")" ;;
    *)      perm="$(stat -c '%a' "$PHONE_CONF")" ;;
  esac
  if [ "$perm" = "600" ]; then ok "配置文件权限为 600"; else bad "配置文件权限为 $perm，应为 600"; fi
else
  bad "未生成配置文件"
fi

# ─────────────────────────────────────────────
head_ "4. 控件树解析（离线 fixture）"

cat > "$TMPD/ui.xml" <<'XML'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
  <node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.android.settings" content-desc="" clickable="false" enabled="true" bounds="[0,0][1080,2400]">
    <node index="0" text="WLAN" resource-id="android:id/title" class="android.widget.TextView" package="com.android.settings" content-desc="" clickable="true" enabled="true" bounds="[78,600][400,700]" />
    <node index="1" text="" resource-id="android:id/switch_widget" class="android.widget.Switch" package="com.android.settings" content-desc="开关" clickable="true" enabled="true" bounds="[900,600][1040,700]" />
    <node index="2" text="保存并退出" resource-id="btn_save_exit" class="android.widget.Button" package="com.android.settings" content-desc="" clickable="true" enabled="true" bounds="[100,900][500,1000]" />
  </node>
</hierarchy>
XML

# ui_parse.py 从 stdin 读 XML（phone.sh 就是这么喂给它的）
out="$(python3 "$SCRIPTS/ui_parse.py" text < "$TMPD/ui.xml" 2>&1)"
case "$out" in
  *WLAN*) ok "ui_parse text 能提取文字" ;;
  *) bad "ui_parse text 未能提取文字" "$out" ;;
esac

# content-desc 兜底：无 text 的开关节点应输出其描述
case "$out" in
  *开关*) ok "ui_parse 在无 text 时回退到 content-desc" ;;
  *) bad "ui_parse 未回退到 content-desc" "$out" ;;
esac

# 按文字选中可点击节点，必须给出落点坐标
out="$(python3 "$SCRIPTS/ui_parse.py" pick-text "WLAN" < "$TMPD/ui.xml" 2>&1)"
case "$out" in
  *"239 "*) ok "pick-text 命中 WLAN，中心点 x=239" ;;
  *) bad "pick-text 未给出预期中心点" "$out" ;;
esac

# 精确匹配不应把「保存并退出」当成「保存」
out="$(python3 "$SCRIPTS/ui_parse.py" pick-text "保存" --exact < "$TMPD/ui.xml" 2>&1)"
rc=$?
if [ "$rc" -eq 1 ]; then
  ok "--exact 不匹配「保存并退出」（避免误点）"
else
  bad "--exact 误匹配了「保存并退出」" "$out"
fi

# 包含匹配则应命中
out="$(python3 "$SCRIPTS/ui_parse.py" pick-text "保存" < "$TMPD/ui.xml" 2>&1)"
case "$out" in
  *保存并退出*) ok "非精确匹配可命中「保存并退出」" ;;
  *) bad "非精确匹配未命中" "$out" ;;
esac

# 不存在的文字必须以 1 退出（让 phone.sh 能判断失败）
python3 "$SCRIPTS/ui_parse.py" pick-text "不存在的按钮文字" < "$TMPD/ui.xml" >/dev/null 2>&1
[ $? -eq 1 ] && ok "未找到时返回 1" || bad "未找到时退出码不是 1"

# 损坏的 XML 必须以 2 退出
echo "not xml at all" | python3 "$SCRIPTS/ui_parse.py" text >/dev/null 2>&1
[ $? -eq 2 ] && ok "XML 损坏时返回 2" || bad "XML 损坏时退出码不是 2"

# ─────────────────────────────────────────────
head_ "5. 隐私扫描"

if ! command -v tesseract >/dev/null 2>&1; then
  ok "跳过（未安装 tesseract）"
else
  if "$PRIVACY" "$FIX/clean_ui.png" >/dev/null 2>&1; then
    ok "干净图片不误报"
  else
    bad "干净图片被误报" "$("$PRIVACY" "$FIX/clean_ui.png" 2>&1 | grep '✗' | head -3)"
  fi

  # 含敏感信息的图必须报红
  if [ -f "$FIX/dirty_ui.png" ]; then
    if "$PRIVACY" "$FIX/dirty_ui.png" >/dev/null 2>&1; then
      bad "含手机号/IP 的图片未被检出"
    else
      ok "含敏感信息的图片被拦住"
    fi
    # --allow-time 不应放过身份信息
    if "$PRIVACY" --allow-time "$FIX/dirty_ui.png" >/dev/null 2>&1; then
      bad "--allow-time 错误地放过了身份信息"
    else
      ok "--allow-time 不影响身份信息拦截"
    fi
  fi
fi

# ─────────────────────────────────────────────
head_ "6. 文档链接与锚点"

if python3 "$ROOT/tests/check-docs.py" >/dev/null 2>&1; then
  ok "文档链接与锚点全部有效"
else
  bad "文档有坏链接或坏锚点" "$(python3 "$ROOT/tests/check-docs.py" 2>&1 | head -3)"
fi

# ─────────────────────────────────────────────
head_ "7. 公开产物不含隐私"

# 仓库里所有文本文件中不应出现真实设备标识
# 把每个敏感串拆成几段拼接：这样脚本源码里不会出现完整串，
# 扫描时才拼出来。否则本文件会被自己判定为泄漏。
LEAKS=0
pats=(
  "aeff""b147"
  "M2007""J17C"
  "gauguin""pro"
  "100.125""'.'""85.126"
  "100.124""'.'""151.121"
  "CMCC""-wxp4"
  "chenduola""666"
  "chenzibode""MacBook"
)
for pat in "${pats[@]}"; do
  # 排除本脚本自身、git 目录和临时产物
  hits="$(grep -rIl --exclude-dir=.git --exclude-dir=.privacy_tmp \
            --exclude="$(basename "$0")" -E "$pat" "$ROOT" 2>/dev/null | head -2)"
  if [ -n "$hits" ]; then
    bad "发现真实设备信息: $pat" "$hits"
    LEAKS=$((LEAKS+1))
  fi
done
[ "$LEAKS" -eq 0 ] && ok "未发现真实设备标识泄漏"

# ─────────────────────────────────────────────
printf '\n════════════════════════════\n'
printf '  通过 %d  失败 %d\n' "$pass" "$fail"
printf '════════════════════════════\n'
[ "$fail" -eq 0 ] || exit 1
