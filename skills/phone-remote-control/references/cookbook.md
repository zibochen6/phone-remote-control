# 命令手册 & 实战配方

> 所有命令都可以加上 `PHONE_MODE=usb|wifi|tailscale` 前缀来指定连接方式。
> 完整命令列表：`phone.sh help`

---

## 命令速查

### 连接与诊断

| 命令 | 作用 |
| --- | --- |
| `phone.sh setup` | 首次接入向导，检测环境并给出下一步 |
| `phone.sh doctor` | 六层诊断，连不上先跑这个 |
| `phone.sh status` | 工具 / 设备 / 屏幕 / 前台，一次看全 |
| `phone.sh devices` | 列出所有设备（USB / TCP）及型号 |
| `phone.sh pair` | 无线调试配对（自动发现端口） |
| `phone.sh connect` | 建立连接并清理同机冗余连接 |
| `phone.sh disconnect --all` | 断开所有 TCP 连接 |
| `phone.sh openport` | [需 USB] 开启 TCP 5555 |
| `phone.sh recover` | 重启后恢复 |
| `phone.sh wake` | 唤醒屏幕（不能解锁） |
| `phone.sh screen` | 屏幕亮灭 / 锁屏状态 / 前台窗口 |

### 读界面（给 agent 用）

| 命令 | 作用 |
| --- | --- |
| `phone.sh shot [--small] [路径]` | 截图；`--small` 出 800px JPEG |
| `phone.sh ui` | 当前界面所有文本，一行一个 |
| `phone.sh nodes` | 所有节点：text / desc / id / class / bounds / flags |
| `phone.sh nodes --json` | 同上，JSON 格式 |
| `phone.sh nodes --all` | 包含不可见 / 不可点击的节点 |
| `phone.sh find <文本>` | 查找含该文本的节点 |
| `phone.sh current` | 当前前台窗口 |

### 操作

| 命令 | 作用 |
| --- | --- |
| `phone.sh tap-text <文本>` | **按文字点击**（首选） |
| `phone.sh tap-text <文本> --exact` | 精确匹配，避免点到"保存"的"保存并退出" |
| `phone.sh tap-id <id片段>` | 按 resource-id 点击 |
| `phone.sh wait-text <文本> [秒]` | 等文字出现，默认 20s |
| `phone.sh scroll-to <文本> [次数]` | 滚动直到找到文字，默认 6 次 |
| `phone.sh tap X Y` | 坐标点击 |
| `phone.sh swipe X1 Y1 X2 Y2 [ms]` | 滑动，默认 300ms |
| `phone.sh key <KEYCODE>` | 按键（`HOME` / `BACK` / `ENTER` / `26`=电源） |
| `phone.sh text <内容>` | 输入文本（ASCII） |
| `phone.sh open <url>` | 打开 URL |
| `phone.sh app <包名>` | 启动应用 |
| `phone.sh apps [关键词]` | 列出已安装的第三方应用 |

### 文件 / 录屏 / 其他

| 命令 | 作用 |
| --- | --- |
| `phone.sh shell <cmd>` | 任意 shell 命令 |
| `phone.sh logcat [行数]` | 最近日志 |
| `phone.sh logcat-clear` | 清空日志缓冲 |
| `phone.sh record [秒] [文件]` | 录屏并拉回（上限 180s） |
| `phone.sh push <本地> <手机>` | 推文件 |
| `phone.sh pull <手机> <本地>` | 拉文件 |
| `phone.sh install <apk>` | 安装 APK |
| `phone.sh mirror [--bg]` | 投屏（需 scrcpy） |
| `phone.sh wait` | 等开机完成 |
| `phone.sh reboot` | 重启（需 `PHONE_ALLOW_REBOOT=1`） |

---

## 核心思路：为什么按文字点击

AI agent 操作手机时，最常见的错误是**靠坐标盲点**。屏幕分辨率、字体大小、
系统版本、语言任何一项变了，坐标就全错。

`tap-text` 的做法是：先 `uiautomator dump` 拿到整棵控件树，在树里找到
`text` 等于目标字符串的节点，读它自己的 `bounds`，算出中心点再点。

```
phone.sh tap-text "WLAN"
✓ 点击「WLAN」@ (540,612)
  text="WLAN" bounds=[30,580]-[1050,645] clickable
```

**好处：**

- 换了语言？只要文本对得上就能点
- 换了分辨率？bounds 是运行时算的，自动适配
- 控件挪位置了？依然正确
- 出错了有明确报错，不会"静默点歪"

**什么时候还得用坐标？**

- 控件没有任何文字（纯图标按钮）→ 用 `nodes` 找到它的 `desc` 或 `id`
- 游戏 / 画布类界面 → 只能坐标
- 验证码 / 手势锁 → 只能坐标

---

## 实战配方

### 配方 1：打开设置并确认某个状态

```bash
#!/usr/bin/env bash
set -e

phone.sh app com.android.settings
phone.sh wait-text "WLAN" 10 || phone.sh wait-text "网络" 10
phone.sh tap-text "WLAN"
phone.sh wait-text "WLAN" 5

# 确认开关状态：找带 Switch 的节点
phone.sh nodes | grep -i switch
```

> 用 `wait-text` 替代固定 `sleep`。`sleep 3` 在慢设备上会翻车，
> 而 `wait-text` 要么立刻过，要么明确报超时。

### 配方 2：每日自动打卡（企业微信 / 钉钉）

```bash
#!/usr/bin/env bash
set -e
phone.sh wake
phone.sh app com.tencent.wework        # 或 com.alibaba.android.rimet

# 打卡入口通常有明确文字
phone.sh wait-text "工作台" 20
phone.sh tap-text "工作台"
phone.sh wait-text "打卡" 15
phone.sh tap-text "打卡"

phone.sh shot --small /tmp/checkin-$(date +%F).jpg
echo "打卡完成，截图已存"
```

配合 cron：

```cron
# 每个工作日 8:55 自动打卡
55 8 * * 1-5 /path/to/checkin.sh >> /tmp/checkin.log 2>&1
```

> **免责提醒**：自动打卡可能有违反公司规定的风险，也可能被 App 检测。
> 这里只演示技术可行性，请自行判断是否合适。

### 配方 3：录制直播间（配合 ffmpeg 拉流）

手机端录制受 180 秒限制，长时间录制要分段拼接：

```bash
#!/usr/bin/env bash
# 分段录 30 分钟，最后拼接
SEG=170
TOTAL=1800
N=$((TOTAL / SEG))
for i in $(seq 1 $N); do
  phone.sh record $SEG "/tmp/seg-$i.mp4"
  echo "第 $i/$N 段完成"
done

# 拼接
ls /tmp/seg-*.mp4 | sort -V | sed "s|^|file '|;s|$|'|" > /tmp/list.txt
ffmpeg -f concat -safe 0 -i /tmp/list.txt -c copy /tmp/full.mp4
```

> 更省事的办法：很多直播平台有拉流地址，直接用 `ffmpeg` 拉，
> 完全不占手机。手机录制只在无法拉流时用。

### 配方 4：App 启动速度基准测试

```bash
#!/usr/bin/env bash
PKG="com.example.app"
phone.sh shell "am force-stop $PKG"
sleep 1

phone.sh logcat-clear
phone.sh app "$PKG"
phone.sh wait-text "" 1 >/dev/null 2>&1 || true

# 从 ActivityManager 日志里抓启动耗时
phone.sh logcat 500 | grep -E "Displayed $PKG" | head -1
```

`logcat` 里 `Displayed com.xxx/.MainActivity: +1s234ms` 就是冷启动耗时。

### 配方 5：界面回归测试（截图比对）

```bash
#!/usr/bin/env bash
set -e
BASELINE="baselines/"

for step in "首页:首页" "我的:我的" "设置:设置"; do
  name="${step%%:*}"; text="${step##*:}"
  phone.sh tap-text "$text"
  phone.sh wait-text "$name" 5
  phone.sh shot --small "/tmp/current-$name.jpg"

  if [ -f "$BASELINE/$name.jpg" ]; then
    # 允许 2% 像素差异
    diff_pct=$(magick compare -metric RMSE \
      "$BASELINE/$name.jpg" "/tmp/current-$name.jpg" null: 2>&1 | awk '{print $1}' | tr -d '()')
    echo "$name 差异: $diff_pct"
  else
    cp "/tmp/current-$name.jpg" "$BASELINE/$name.jpg"
    echo "$name 已建立基线"
  fi
done
```

### 配方 6：监控电量并低电告警

```bash
#!/usr/bin/env bash
LEVEL=$(phone.sh shell "dumpsys battery" | awk -F': ' '/level/{print $2}')
STATUS=$(phone.sh shell "dumpsys battery" | awk -F': ' '/status/{print $2}')
# status: 2=充电中 5=满电 其它=放电
echo "电量: ${LEVEL}%  状态码: ${STATUS}"

if [ "$LEVEL" -lt 20 ] && [ "$STATUS" != "2" ] && [ "$STATUS" != "5" ]; then
  echo "⚠ 电量低且未充电"
  phone.sh shell "cmd notification post -S bigtext -t '手机低电' tag '电量 ${LEVEL}%'"
fi
```

### 配方 7：让 AI agent 完成「找到并点击」

这是本工具真正的价值所在 —— 给 agent 一段可复用的决策循环：

```
1. phone.sh ui                    # 看看屏幕上有什么
2. 决定下一步做什么
3. phone.sh tap-text "<目标>"      # 按文字点，不猜坐标
4. phone.sh wait-text "<预期结果>"  # 确认这步成功了
5. 回到 1，直到目标达成
```

每一步都有明确的成功/失败信号。失败了 agent 能读到错误并换策略，
而不是像纯视觉方案那样"看起来点了但其实没点中"。

---

## 环境变量

| 变量 | 作用 | 默认 |
| --- | --- | --- |
| `PHONE_MODE` | `auto` / `usb` / `wifi` / `tailscale` | `auto` |
| `PHONE_SERIAL` | 指定设备序列号或 `ip:port` | 自动 |
| `PHONE_CONF` | 配置文件路径 | `~/.phone-remote.conf` |
| `PHONE_HOST` | Tailscale 中手机的主机名 | 从配置读 |
| `PHONE_IP` | 直接钉死 Tailscale IP | 从配置读 |
| `PHONE_ADB_TIMEOUT` | 单条 adb 命令超时秒数 | `20` |
| `PHONE_ALLOW_REBOOT` | 设为 `1` 才允许 reboot | `0` |
| `ADB_BIN` | adb 路径 | 自动查找 |
| `SCRCPY_BIN` | scrcpy 路径 | 自动查找 |
| `TAILSCALE_BIN` | tailscale 路径 | 自动查找 |

---

## 配置文件

`~/.phone-remote.conf`（权限 600，首次运行自动生成）：

```ini
MODE=auto
ADB_PORT=5555
# 无线调试地址，pair 成功后自动写入
WIFI_ADDR=192.168.1.23:37001
# 多台 USB 设备时指定
PHONE_SERIAL=<SERIAL>
# Tailscale 模式
TS_HOST=<YOUR_PHONE>
PHONE_IP=100.x.x.x
```

**这个文件包含你的网络信息，不要提交到 Git。** 仓库的 `.gitignore` 已经排除了它。
