#!/usr/bin/env bash
# ============================================================================
# privacy_scan.sh — 截图发布前的隐私红线检查
#
# 用途：在把手机截图放进 README / 文档 / 社交媒体之前，自动找出可能泄露
#       隐私的内容。设计原则是「宁可误报，不可漏报」。
#
# 依赖：tesseract（OCR，必需）、magick（可选，用于自动打码）
#   macOS: brew install tesseract tesseract-lang imagemagick
#   Linux: sudo apt install tesseract-ocr tesseract-ocr-chi-sim imagemagick
#
# 用法：
#   privacy_scan.sh <图片...>          # 扫描，有风险则非零退出
#   privacy_scan.sh --strict <图片...> # 额外报出中文App名等提示性内容
#   privacy_scan.sh --mask <图> <输出> --regions "0,0,1080,120;..."
#                                       # 按矩形区域涂黑后另存
#
# 退出码：0 = 干净；1 = 发现敏感信息；2 = 使用错误/依赖缺失
# ============================================================================
set -uo pipefail

RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; RST=$'\033[0m'
[ -t 1 ] || { RED=""; YEL=""; GRN=""; DIM=""; RST=""; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# 临时目录：不要用 /tmp 或 /var/folders —— Leptonica 在这些位置读取经常失败
WORK_TMP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.privacy_tmp"
mkdir -p "$WORK_TMP"
trap 'rm -rf "$WORK_TMP"' EXIT

# 敏感信息规则：名称<TAB>ERE
# 顺序无所谓，全部都会跑
rules() {
  cat <<'EOF'
手机号	\b1[3-9][0-9]{9}\b
内网/Tailscale IP	\b(100|10|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b
任意 IPv4	\b[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b
邮箱	[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}
Wi-Fi 名称	(CMCC|CU_|ChinaNet|TP-?LINK|Xiaomi_|HUAWEI-|H3C|MERCURY|FAST_|Redmi_|FAST|ZTE|Tenda)[A-Za-z0-9_-]*
疑似 SSID	[A-Za-z0-9][A-Za-z0-9_-]{2,}(-5G|_5G|5G)\b

序列号/型号	\b(M2[0-9]{3}J[0-9]{2}[A-Z]|[A-Z0-9]{8,12})\b
MAC 地址	\b([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b
身份证	\b[1-9][0-9]{5}(19|20)[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9Xx]\b
验证码/密码提示	(验证码|动态码|密码|口令)[:：]?\s*[0-9]{4,8}
电量百分比	\b[0-9]{1,3}%$
EOF
}

# 环境信息：不含身份，但会暴露"什么时候拍的/设备状态"。
# 默认也报（安全优先），--allow-time 可跳过。
env_rules() {
  cat <<'EOF'
状态栏时间	\b([01]?[0-9]|2[0-3]):[0-5][0-9]\b
网速	[0-9]+(\.[0-9]+)?[KMG]B?/s
电量	\b[0-9]{1,3}%
EOF
}

# 中文提示性内容（非必然泄露，但发布前应人工确认）
hint_rules() {
  cat <<'EOF'
聊天/社交	(微信|QQ|钉钉|企业微信|飞书|短信|通话记录|通讯录)
支付/金融	(支付宝|微信支付|余额|账单|银行卡|花呗|借呗|信用卡|转账)
个人信息	(实名|身份证|收货地址|常用地址|家庭成员|生日)
他人内容	(直播间|粉丝|关注|私信|评论|观看历史)
EOF
}

scan_one() {
  local img="$1" strict="$2" allow_time="${3:-0}"
  local tmp base hits=0
  [ -f "$img" ] || { echo "  ${RED}✗ 文件不存在${RST}: $img"; return 2; }

  # 注意：tesseract 在 macOS 的 /var/folders 临时目录下写文件偶发失败，
  # 因此临时文件固定放在系统 tmp 下并显式建名字
  tmp="${WORK_TMP}/pscan.$$.${RANDOM}"
  # OCR：中文 + 英文。psm 6 适合界面截图（整块文本）
  # 单独探测一次，便于区分「语言包缺失」和「图片读不了」
  local ocr_err
  # 参数顺序敏感：-l/--psm 必须在"输入 输出"之前，否则 tesseract 会把图片路径当输出名
  if ! ocr_err="$(tesseract -l chi_sim+eng --psm 6 "$img" "$tmp" 2>&1)"; then
    rm -f "$tmp" "$tmp.txt"
    echo "  ${YEL}⚠ OCR 失败${RST}"
    printf '%s\n' "$ocr_err" | head -3 | sed 's/^/      /'
    if ! tesseract --list-langs 2>/dev/null | grep -q '^chi_sim$'; then
      echo "    缺少中文语言包："
      case "$(uname -s)" in
        Darwin) echo "      brew install tesseract-lang" ;;
        *)      echo "      sudo apt install tesseract-ocr-chi-sim" ;;
      esac
    fi
    return 2
  fi
  local text; text="$(cat "$tmp.txt" 2>/dev/null)"
  rm -f "$tmp" "$tmp.txt"

  if [ -z "$(printf '%s' "$text" | tr -d '[:space:]')" ]; then
    echo "  ${YEL}⚠ 未识别出任何文字${RST}（纯图片/空白页？需人工确认）"
    return 0
  fi

  while IFS=$'\t' read -r name re; do
    [ -n "$re" ] || continue
    local found
    found="$(printf '%s' "$text" | grep -Eo "$re" 2>/dev/null | sort -u | head -3)"
    if [ -n "$found" ]; then
      hits=$((hits+1))
      echo "  ${RED}✗ ${name}${RST}"
      printf '%s\n' "$found" | sed "s/^/      → /"
    fi
  done < <(rules)

  if [ "$allow_time" = "1" ]; then
    : # 用户明确表示时间类数字可接受（如闹钟/秒表截图）
  else
    while IFS=$'\t' read -r name re; do
      [ -n "$re" ] || continue
      local found
      found="$(printf '%s' "$text" | grep -Eo "$re" 2>/dev/null | sort -u | head -3)"
      if [ -n "$found" ]; then
        hits=$((hits+1))
        echo "  ${RED}✗ ${name}${RST}"
        printf '%s\n' "$found" | sed "s/^/      → /"
        echo "      ${DIM}（若为闹钟/秒表等纯时间界面，可用 --allow-time 跳过）${RST}"
      fi
    done < <(env_rules)
  fi

  if [ "$strict" = 1 ]; then
    while IFS=$'\t' read -r name re; do
      [ -n "$re" ] || continue
      local found
      found="$(printf '%s' "$text" | grep -Eo "$re" 2>/dev/null | sort -u | head -3)"
      if [ -n "$found" ]; then
        echo "  ${YEL}? ${name}${RST}（需人工判断是否可发布）"
        printf '%s\n' "$found" | sed "s/^/      → /"
      fi
    done < <(hint_rules)
  fi

  return "$([ "$hits" -gt 0 ] && echo 1 || echo 0)"
}

do_mask() {
  local img="$1" out="$2" regions="$3"
  need_cmd magick || { echo "✗ 需要 imagemagick：brew install imagemagick" >&2; return 2; }
  local args=() r x y w h
  IFS=';' read -ra parts <<< "$regions"
  for r in "${parts[@]}"; do
    [ -n "$r" ] || continue
    IFS=',' read -r x y w h <<< "$r"
    args+=( -fill black -draw "rectangle ${x},${y} $((x+w)),$((y+h))" )
  done
  magick "$img" "${args[@]}" "$out" || { echo "✗ 打码失败" >&2; return 1; }
  echo "✓ 已打码 → $out"
}


# 自动打码：OCR 出每个词的坐标，命中敏感规则的整段涂黑
do_auto_mask() {
  local img="$1" out="$2" force="${3:-}" statusbar="${4:-0}"
  need_cmd magick || { echo "✗ 需要 imagemagick：brew install imagemagick" >&2; return 2; }
  need_cmd tesseract || { echo "✗ 需要 tesseract" >&2; return 2; }

  # 白字（如蓝底高亮卡片上的当前 SSID）在常规 OCR 下常被漏掉，
  # 因此跑两遍：原图 + 反色图，两轮坐标合并。
  local tmp="${WORK_TMP}/pscan.$$"
  local inv="${WORK_TMP}/pscan.inv.$$.png"
  local wht="${WORK_TMP}/pscan.wht.$$.png"
  # 1) 反色：抓深色底上的浅色字
  magick "$img" -negate "$inv" >/dev/null 2>&1 || inv=""
  # 2) 近白像素单独提出来：抓高亮卡片（如蓝色按钮）上的白字 —— 反色也抓不到这类
  magick "$img" -fuzz 30% -fill black +opaque white -fill white -opaque white "$wht" >/dev/null 2>&1 || wht=""
  for _src in "$img" "$inv" "$wht"; do
    [ -n "$_src" ] || continue
    [ -f "$_src" ] || continue
    tesseract -l chi_sim+eng --psm 6 "$_src" "${tmp}.multi" tsv >/dev/null 2>&1 \
      && cat "${tmp}.multi.tsv" >> "${tmp}.all.tsv"
  done
  [ -s "${tmp}.all.tsv" ] || { echo "✗ OCR 失败，无法自动定位" >&2
    rm -f "${tmp}.all.tsv" "${tmp}.multi.tsv" "$inv" "$wht"; return 1; }

  # 收集所有命中规则的词坐标
  local -a boxes=()
  local text line_no name_re
  # 合并所有规则为一个 ERE，逐个词判断
  local all_re
  all_re="$(rules | cut -f2 | tr '\n' '|' | sed 's/|$//')"

  while IFS=$'\t' read -r level page block par line word left top width height conf txt; do
    [ "$level" = "5" ] || continue
    [ -n "$txt" ] || continue
    if printf '%s' "$txt" | grep -Eq "$all_re" 2>/dev/null; then
      # 向外扩一点边距，避免残字
      local x0=$((left - 6)) y0=$((top - 3))
      local w=$((width + 12)) h=$((height + 6))
      boxes+=( -fill black -draw "rectangle ${x0},${y0} $((x0+w)),$((y0+h))" )
    fi
  done < "${tmp}.all.tsv"
  rm -f "${tmp}.all.tsv" "${tmp}.multi.tsv" "$inv" "$wht"

  # 强制区域：OCR 读不到的（如反色卡片上的白字）必须靠人工指定，这是最后一道保险
  local r x y w h
  if [ -n "$force" ]; then
    IFS=';' read -ra _fparts <<< "$force"
    for r in "${_fparts[@]}"; do
      [ -n "$r" ] || continue
      IFS=',' read -r x y w h <<< "$r"
      [ -n "${h:-}" ] || continue
      boxes+=( -fill black -draw "rectangle ${x},${y} $((x+w)),$((y+h))" )
    done
  fi
  # 状态栏整条涂黑（最省事也最稳）
  if [ "$statusbar" = "1" ]; then
    local iw ih
    iw="$(magick identify -format '%w' "$img" 2>/dev/null)"
    ih="$(magick identify -format '%h' "$img" 2>/dev/null)"
    iw="${iw:-1080}"
    boxes+=( -fill black -draw "rectangle 0,0 ${iw},$((ih * 6 / 100))" )
  fi

  if [ ${#boxes[@]} -eq 0 ]; then
    echo "✓ 未发现需要打码的文字，直接复制"
    cp "$img" "$out"
    return 0
  fi
  magick "$img" "${boxes[@]}" "$out" || { echo "✗ 打码失败" >&2; return 1; }
  echo "✓ 已自动打码 $(( ${#boxes[@]} / 4 )) 处 → $out"
}

# ---------------------------------------------------------------- 主流程
if [ $# -eq 0 ]; then
  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
fi

if [ "$1" = "--auto-mask" ]; then
  shift
  [ $# -ge 2 ] || { echo "用法: privacy_scan.sh --auto-mask <图> <输出> [--regions \"x,y,w,h;...\"] [--statusbar]" >&2; exit 2; }
  MASK_IN="$1"; MASK_OUT="$2"; shift 2
  FORCE_REGIONS=""; STATUS_BAR=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --regions)   FORCE_REGIONS="${2:-}"; shift 2 ;;
      --statusbar) STATUS_BAR=1; shift ;;
      *) shift ;;
    esac
  done
  do_auto_mask "$MASK_IN" "$MASK_OUT" "$FORCE_REGIONS" "$STATUS_BAR"
  exit $?
fi

if [ "$1" = "--mask" ]; then
  shift
  [ $# -ge 2 ] || { echo "用法: privacy_scan.sh --mask <图> <输出> --regions \"x,y,w,h;...\"" >&2; exit 2; }
  img="$1"; out="$2"; shift 2
  regions="${2:-}"
  [ "${1:-}" = "--regions" ] && regions="${2:-}"
  do_mask "$img" "$out" "$regions"
  exit $?
fi

STRICT=0
ALLOW_TIME=0
while [ $# -gt 0 ]; do
  case "$1" in
    --strict)     STRICT=1; shift ;;
    --allow-time) ALLOW_TIME=1; shift ;;
    --)           shift; break ;;
    *)            break ;;
  esac
done

need_cmd tesseract || {
  echo "✗ 需要 tesseract 做 OCR：" >&2
  echo "  macOS: brew install tesseract tesseract-lang" >&2
  echo "  Linux: sudo apt install tesseract-ocr tesseract-ocr-chi-sim" >&2
  exit 2
}

echo "═══ 隐私扫描（$(count_args=$#; echo "$count_args") 张图）═══"
total_bad=0
for img in "$@"; do
  echo "── $(basename "$img")"
  scan_one "$img" "$STRICT" "$ALLOW_TIME"
  rc=$?
  case "$rc" in
    0) ;;
    1) total_bad=$((total_bad+1)) ;;
    *) total_bad=$((total_bad+1)) ;;
  esac
done

echo "════════════════════"
if [ "$total_bad" -gt 0 ]; then
  echo "${RED}✗ ${total_bad} 张图存在风险，请打码或换图后重扫${RST}"
  echo "${DIM}  打码示例：privacy_scan.sh --mask a.png b.png --regions \"0,0,1080,130\"${RST}"
  exit 1
fi
echo "${GRN}✅ 未发现敏感信息${RST}（仍建议人工看一遍再发布）"
exit 0
