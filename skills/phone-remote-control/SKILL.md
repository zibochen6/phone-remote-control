---
name: phone-remote-control
description: 用 adb 远程操作 Android 手机 —— 截图、按文字点击、识别界面、录屏、投屏、自动化流程。支持 USB 数据线、同网 Wi-Fi 无线调试、Tailscale 异地控制三种接入方式。当用户要求"控制/操作手机""在手机上点某个按钮""看手机屏幕上有什么""录手机屏幕""自动化手机操作"时使用本 skill。也适用于让 AI agent 通过界面文本而非固定坐标来可靠地驱动手机。
agent_created: true
---

# 手机远程控制

用一条 shell 脚本把 Android 手机变成 agent 可以读、可以点的界面。

**核心理念：按文字点击，不靠固定坐标。** 坐标会因分辨率、语言、系统版本变化而失效；
文字不会。这让 agent 的操作可复现、可验证、失败时能读懂原因。

---

## 第一步：先诊断

**任何手机操作之前，先跑这一条：**

```bash
bash scripts/phone.sh doctor
```

它按六层检查（工具 → 设备 → mDNS → Tailscale → 端口 → adb+界面解析），
直接告诉你断在哪一层、下一步该做什么。

如果 `doctor` 报"没有找到设备"，向用户确认接入方式，然后按对应文档引导：

| 用户的手机 | 用哪个文档 |
| --- | --- |
| Android 11+，愿意在手机点几下 | `references/setup-wireless.md`（**推荐，不需线**） |
| Android 10 及以下，或有数据线 | `references/setup-usb.md` |
| 手机不在同一网络（想在外网控制） | `references/setup-tailscale.md` |

`references/troubleshooting.md` 有六层问题的逐条解法。

---

## 关键约束（务必先读，否则会浪费很多时间理解为什么失败）

### 1. 重启后必须重新连接

| 接入方式 | 重启后 |
| --- | --- |
| 无线调试（Android 11+） | 失效，需在手机上重开无线调试并重新配对 |
| `adb tcpip 5555` | 失效，需插 USB 后 `phone.sh openport` |
| USB | 可用（可能需重新授权） |

`phone.sh recover` 会把恢复步骤列出来。**不要试图绕过**——这需要 root，
而且属于系统设计上的安全边界。

### 2. 锁屏状态下几乎无法操作

`phone.sh wake` 只能**点亮屏幕**，不能解锁。

- 锁屏界面读不到应用内容
- 坐标点击在锁屏界面常被系统吞掉

**需要用户在手机上手动解锁。** 这是硬限制，不要尝试猜密码或画图案。

### 3. 中文输入需要额外安装

Android 的 `input text` **只支持 ASCII**。输入中文会报
`NullPointerException` 或无效。解决方案见 `references/troubleshooting.md` §5。

**更好的做法：不要输入中文。** 大多数场景用 `tap-text` 点进去、
或 `phone.sh app <包名>` 直接跳转，比输入搜索词更可靠。

### 4. 部分 App 禁止界面读取

银行、部分视频类 App 会阻止 `uiautomator dump` 与截图。
这是对方的安全策略，**无解**，除非该 App 提供开放接口。

### 5. 三方 App 名称与文本因语言而异

`tap-text "Settings"` 在中文系统上找不到。要么用 `nodes` 看实际文本，
要么先 `phone.sh shell "settings get system system_locales"` 确认语言，
要么用 `resource-id` 定位（`tap-id`）。

---

## 常用命令

完整列表见 `references/cookbook.md` 或 `phone.sh help`。

```bash
# 读
phone.sh status                    # 一次看全
phone.sh shot --small /tmp/a.jpg   # 截图
phone.sh ui                        # 当前界面的所有文字
phone.sh nodes                     # 控件树：text/desc/id/bounds/flags
phone.sh find "WLAN"               # 找含该文字的控件

# 点
phone.sh tap-text "WLAN"           # 按文字点击 ← 首选
phone.sh tap-text "保存" --exact     # 精确匹配，防止点到"保存并退出"
phone.sh tap-id "btn_ok"           # 按 resource-id
phone.sh tap 540 1200              # 坐标（最后手段）

# 等
phone.sh wait-text "已连接" 15       # 等文字出现 ← 用它代替 sleep
phone.sh scroll-to "版本号" 6       # 滚动直到找到

# 其他
phone.sh app com.android.settings  # 启动应用
phone.sh key HOME                  # 按键
phone.sh record 10 /tmp/a.mp4      # 录屏
phone.sh mirror --bg               # 后台投屏
```

**用 `wait-text` 替代 `sleep`。** 固定 sleep 在慢设备上会翻车，
`wait-text` 要么立刻通过、要么明确报超时。

---

## Agent 操作循环

这是本 skill 的推荐工作方式。每一轮都有明确成功/失败信号，
失败时能读到原因并换策略：

```
1. phone.sh ui
   → 屏幕上现在有什么

2. 决定下一个动作

3. phone.sh tap-text "<目标>"
   → 成功打印坐标和命中的控件，失败打印"未找到"

4. phone.sh wait-text "<预期出现的内容>" 15
   → 确认这一步真的生效了

5. 回 1，直到目标达成

6. phone.sh shot --small /tmp/result.jpg
   → 留证据给用户看
```

**为什么不用纯视觉方案：** 视觉模型可能"看起来点了"但实际偏了几十像素，
而且无法判断点击是否生效。`uiautomator` 的控件树是系统的真实状态，
点完能立刻读回来验证。

---

## 隐私红线

操作手机很容易碰到用户的私人数据。**以下规则不可协商：**

### 绝不主动读取

- 相册 / 照片 / 视频
- 短信 / 通话记录 / 通讯录
- 微信 / QQ / 其他聊天内容
- 银行、支付、密码、验证码相关界面
- 剪贴板

如果任务必须经过这些界面，只做**导航**，不读取、不截图、不回传内容。

### 截图 / 录屏前

- 只截与任务相关的界面
- 遇到状态栏、通知、账号名、Wi-Fi 名称、手机号，**先打码或裁掉**
- 生成要分享给用户的图片前，跑一遍检查：

```bash
bash scripts/privacy_scan.sh /tmp/shot.jpg
```

它会 OCR 出手机号、IP、邮箱、SSID、序列号、身份证等并报红。
需要自动打码：

```bash
bash scripts/privacy_scan.sh --auto-mask /tmp/shot.jpg /tmp/shot-safe.jpg --statusbar
```

> **注意：`--auto-mask` 不是万能的。** 它是 OCR 驱动的，读不出来的文字
> （例如高亮卡片上的白字）会漏。已知会漏的地方请用 `--regions "x,y,w,h"` 手动补。
> **发布前必须自己再看一眼图。**

### 任务结束后

- 删除临时推送的文件：`phone.sh shell "rm -f /sdcard/xxx"`
- 清理临时截图
- 不要留下后台录屏 / 投屏进程，除非用户要求

---

## 危险操作：必须先问用户

以下操作在**没有得到用户明确同意**前不要执行：

- `reboot`（脚本默认要求 `PHONE_ALLOW_REBOOT=1`，这是故意的）
- 卸载 / 停用 App
- 恢复出厂设置、清除数据
- 修改系统设置（开发者选项、输入法）
- 安装来源不明的 APK
- 发送短信、拨打电话、转账支付
- 任何会花用户钱的操作

---

## 环境变量

| 变量 | 作用 |
| --- | --- |
| `PHONE_MODE` | `auto`（默认）/ `usb` / `wifi` / `tailscale` |
| `PHONE_SERIAL` | 指定设备 |
| `PHONE_HOST` / `PHONE_IP` | Tailscale 目标 |
| `PHONE_ADB_TIMEOUT` | 单条 adb 超时（默认 20s） |
| `PHONE_ALLOW_REBOOT` | 设为 `1` 才允许 reboot |

配置文件 `~/.phone-remote.conf`（自动生成，权限 600）。

---

## 依赖

| 工具 | 必需 | 用途 |
| --- | --- | --- |
| adb | ✅ | 一切的基础 |
| python3 | 强烈建议 | `nodes` / `tap-text` / `wait-text` / `scroll-to` |
| scrcpy | 可选 | `mirror` 投屏 |
| tesseract | 可选 | `privacy_scan.sh` |
| magick | 可选 | 打码、图片处理 |
| ffmpeg | 可选 | 录屏拼接 |

没有 python3 时，截图、点击、shell 仍可用，但**按文字操作全部失效**——
对 agent 来说这等于废掉一半能力。

安装：

```bash
brew install --cask android-platform-tools   # macOS
brew install python3 scrcpy tesseract tesseract-lang imagemagick ffmpeg
```
