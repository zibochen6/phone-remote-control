# 故障排查

> **永远先跑这一条：**
>
> ```bash
> phone.sh doctor
> ```
>
> 它按「工具 → 设备 → 链路 → 端口 → adb → 界面」六层检查，会直接告诉你断在哪一层。

---

## 一张图定位问题

```
phone.sh doctor 报错
│
├─ 【0】找不到 adb ────────────────→ 见 §1 工具缺失
├─ 【1】无设备 / unauthorized ─────→ 见 §2 连接问题
├─ 【2】没有 mDNS 服务 ────────────→ 见 §3 无线调试
├─ 【3】Tailscale offline ─────────→ 见 §4 穿透问题
├─ 【4】连上但界面解析失败 ─────────→ 见 §5 界面读取
└─ 全部 ✓ 但操作没效果 ────────────→ 见 §6 操作无效
```

---

## §1 工具缺失

### 找不到 adb

```bash
phone.sh status
# adb      : （空）
```

装它：

```bash
# macOS
brew install --cask android-platform-tools

# Ubuntu / Debian
sudo apt install android-tools-adb
```

装完还找不到，可能是 PATH 问题。直接指定：

```bash
export ADB_BIN=/path/to/adb
```

### 找不到 python3

`python3` 缺失时，这些命令不可用：`nodes`、`tap-text`、`wait-text`、`scroll-to`。

`phone.sh` 本身仍然能跑（截图、点击、shell 都行），但**按文字操作**用不了，
对 AI agent 来说这等于废了一半功。装一下：

```bash
# macOS 自带，或用 brew
brew install python3

# Ubuntu / Debian
sudo apt install python3
```

### 找不到 scrcpy

只影响 `phone.sh mirror`（投屏）。不影响其他功能。

```bash
brew install scrcpy        # macOS
sudo apt install scrcpy    # Linux
```

---

## §2 连接问题

### `adb devices` 完全没输出

按可能性排序：

1. **线只能充电。** 换一根。这是最常见的原因，占一半以上。
2. **USB 用途没选「传输文件」。** 手机通知栏 → USB 用途 → 传输文件。
3. **USB 调试没开。** 开发者选项里打开。
4. **USB 驱动问题**（Windows）。装厂商驱动或用 Google USB Driver。

### `unauthorized`

手机没允许这台电脑。

- 看手机屏幕，会有一个「允许 USB 调试吗」的弹窗 → 勾选「一律允许」→ 允许
- 没弹窗就重置一下授权：

```bash
adb kill-server
adb start-server
# 拔插数据线
adb devices
```

还不行 → 手机开发者选项里点 **撤销 USB 调试授权**，再重插。

### `offline`

连接假死（通常是拔插过快或休眠导致）：

```bash
adb kill-server
adb start-server
phone.sh connect
```

无线连接的话：

```bash
phone.sh disconnect --all
phone.sh connect
```

### 多台设备，命令打到了错的手机

```bash
phone.sh devices          # 看清序列号
PHONE_SERIAL=<序列号> phone.sh screen
```

或者写进配置：

```bash
echo "PHONE_SERIAL=<序列号>" >> ~/.phone-remote.conf
```

### 报「同机冗余连接 / Server connection failed」

同一台手机同时通过 USB 和 TCP 连着，scrcpy 会犯迷糊。
`phone.sh` 会自动清理，手动的话：

```bash
adb disconnect <ip:port>
```

---

## §3 无线调试（Android 11+）

### `phone.sh pair` 说「未自动发现配对服务」

依次确认：

1. ✅ 手机开发者选项 → **无线调试**已打开（不是只开了 USB 调试）
2. ✅ 手机和电脑在**同一个 Wi-Fi**（注意别一个连 2.4G 一个连 5G 的不同 SSID 也可能跨网段）
3. ✅ 你**正停留在手机上那个配对弹框**（关掉弹框后 mDNS 广播会消失）
4. ✅ 路由器没有开启 **AP 隔离 / 客户端隔离**（开了设备互相看不见）

手动传入也是可以的 —— 手机弹框上就写着：

```bash
phone.sh pair 192.168.1.23:41234 123456
```

### 配对成功但连不上

```
✓ Successfully paired
⚠ 配对成功但未能自动连接
```

配对用的端口和**连接用的端口不是同一个**。手机重新打开一次「无线调试」，
然后：

```bash
phone.sh connect
```

### 重启后又连不上了

**这是正常的**，无线调试不跨重启。重新开无线调试 + `phone.sh pair`。
详见 [无线调试文档的限制说明](setup-wireless.md#必须知道的限制重启后要重新开)。

### 小米/Redmi 打不开无线调试

MIUI 要求登录小米账号并插 SIM 卡才能开无线调试。若卡住：

- 先用 [USB](setup-usb.md)，再 `phone.sh openport` 转无线
- 这条路的稳定性其实更好

---

## §4 Tailscale / 异地控制

### 手机节点 `offline`

1. 手机上打开 Tailscale App，确认开关是开的
2. **是不是装了 Clash / Surge / 其他代理？** 它们抢占系统 VPN 槽位，
   导致 Tailscale 起不来。先关代理
3. 某些 Roma 会「省电」杀掉后台 VPN，把 Tailscale 加入电池优化白名单

### 节点 `active` 但 `adb connect` 失败

说明 Tailscale 层通了，但 adb 端口没开：

1. 手机重启过 → `adb tcpip 5555` 失效了
2. 插一次 USB 线，跑 `phone.sh recover`
3. 或者用无线调试连上后跑 `phone.sh openport`

手动确认端口通不通：

```bash
nc -z -v 100.x.x.x 5555
```

### `tailscale ping` 不通

DNS 或路由问题：

```bash
tailscale status              # 看是不是还在登录状态
tailscale netcheck            # 检查 NAT / DERP 中继
```

公司网络常会拦 UDP，导致只能走 DERP 中继（慢但能用）。

### 公司电脑不能装 Tailscale

那就只能反向操作：**让手机主动连电脑**，或者用一台家里的设备做跳板。
这超出了本工具的范围，但思路是在家里机器上跑：

```bash
phone.sh connect                          # 家里机器连手机
ssh -R 5555:localhost:5555 公司机器        # 反向隧道
```

---

## §5 界面读取失败

### `nodes` / `tap-text` 报「界面解析失败」或返回空

**在 `doctor` 里对应 `✗ 界面解析失败`。** 按顺序排查：

1. **屏幕锁着。** 最常见。`phone.sh wake` 只能亮屏，**解锁必须手动**
   （锁屏界面 `uiautomator dump` 拿不到应用内容）
2. **屏幕熄了。** `phone.sh wake` 后再试
3. **页面在加载中。** 等一下，或用 `phone.sh wait-text "预期文字" 15`
4. **某些 App 禁止截图/读界面**（银行、部分视频 App）。
   这是对方的安全策略，无解，除非该 App 内部有开放接口
5. **屏幕上有系统级悬浮层**（如录屏指示、无障碍浮窗），偶尔会干扰 dump

### 中文输入失败

```
✗ 中文/emoji 需要 ADBKeyboard 输入法
```

Android 的 `input text` **只支持 ASCII**，这是系统限制。

三个选择：

1. **装 ADBKeyboard**（能输入任意文本）
   - 下载 [ADBKeyBoard](https://github.com/senzhk/ADBKeyBoard/releases) 的 APK
   - `phone.sh install adbkeyboard.apk`
   - 手机设置 → 语言与输入法 → 当前输入法 → 选 **ADBKeyboard**
   - 然后 `phone.sh text "中文"` 就能用了

2. **改用界面操作代替输入**（推荐给 agent）
   - 大多数场景只是想搜个东西，用 `tap-text "搜索框"` + 输入拼音/英文即可
   - 或者直接用 `phone.sh app <包名>` 跳转过去，不经过搜索

3. **剪贴板传入**（需要 App 支持粘贴）
   ```bash
   phone.sh shell "am broadcast -a clipper.set -e text '中文内容'"
   phone.sh key 279   # KEYCODE_PASTE
   ```
   需要装 [Clipper](https://github.com/majido/clipper) 这类 App。

---

## §6 连上了但操作没效果

| 现象 | 原因 | 解法 |
| --- | --- | --- |
| `tap` 无反应 | 锁屏中 | 手动解锁；锁屏时坐标点击被系统吞掉 |
| `tap` 无反应 | 点在不可交互区域 | 用 `phone.sh nodes` 看 `flags` 里有没有 `clickable` |
| `tap-text` 找到但点错地方 | 多个同名控件，点了第一个 | 用 `--exact` 精确匹配，或先 `nodes` 看清 bounds 再 `tap x y` |
| `swipe` 不滚动 | 手势太快被识别为滑动抛掷 | 加时长参数：`phone.sh swipe 540 1800 540 700 800` |
| 开机后所有命令超时 | 手机还在启动 | `phone.sh wait`（等到 `sys.boot_completed=1`） |
| 命令卡住不返回 | adb 挂起 | 已内置 20s 超时；可调 `PHONE_ADB_TIMEOUT=60` |

---

## 还是有解决不了的问题？

收集这些信息再提问（顺便保护隐私，**别发原始截图**）：

```bash
phone.sh doctor 2>&1 | sed 's/[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/<IP>/g'
phone.sh version
adb version
uname -a
```

提 issue 时请附上以上输出，并说明手机型号与 Android 版本。
