# 应用案例

这里收集了「用 Agent 操作手机」能真正省事或省钱的场景。
每个案例都标了**难度**和**能直接跑的命令**，不是空想。

> 有自己跑通的案例？欢迎 PR 补充。格式照抄下面的即可。

---

## 目录

- [内容创作与归档](#内容创作与归档)
- [日常事务自动化](#日常事务自动化)
- [开发与测试](#开发与测试)
- [生活与照看](#生活与照看)
- [AI Agent 集成](#ai-agent-集成)
- [还没人做，但可行](#还没人做但可行)

---

## 内容创作与归档

### 1. 直播录制与归档 ⭐⭐

**痛点：** 有些直播只在手机 App 里能看，电脑端没有入口，或者有 DRM。

**做法：** 手机挂在充电器上，脚本定时开播就录，分段存本地。

```bash
phone.sh app com.ss.android.ugc.aweme
phone.sh wait-text "直播" 20
phone.sh tap-text "直播"
phone.sh wait-text "在线" 30

# 分段录，单段上限 180 秒（Android 系统限制）
for i in $(seq 1 10); do
  phone.sh record 180 /tmp/seg_$i.mp4
done

# 拼接
ffmpeg -f concat -safe 0 -i <(for f in /tmp/seg_*.mp4; do echo "file '$f'"; done) \
       -c copy /tmp/full.mp4
```

**坑：** 录屏会吃 CPU 和电量，长时录制建议插电 + 开飞行模式（用 Wi-Fi）。
`record` 的 180 秒上限是 Android 的硬限制，不是本项目的限制。

---

### 2. 素材批量导出 ⭐⭐⭐

**痛点：** 手机里剪好的视频，一个个手动传太烦。

```bash
# 找到最近修改的视频
phone.sh shell "ls -t /sdcard/DCIM/Camera/*.mp4 | head -5"

for f in $(phone.sh shell "ls -t /sdcard/DCIM/Camera/*.mp4 | head -5"); do
  phone.sh pull "$f" ./raw/
done
```

---

## 日常事务自动化

### 3. 每日自动打卡 ⭐

**痛点：** 每天 9 点要打卡，出差/开会容易忘。

```bash
#!/usr/bin/env bash
# ~/bin/checkin.sh
set -e
phone.sh wake
phone.sh app com.tencent.wework
phone.sh wait-text "工作台" 25
phone.sh tap-text "工作台"
phone.sh wait-text "打卡" 10
phone.sh tap-text "打卡"
phone.sh wait-text "打卡成功" 15 || {
  phone.sh shot --small /tmp/checkin-fail-$(date +%F_%H%M).jpg
  echo "打卡失败，截图已存" >&2
  exit 1
}
```

```cron
# 工作日 8:55
55 8 * * 1-5 /Users/you/bin/checkin.sh >> /tmp/checkin.log 2>&1
```

**关键点：** 一定要有 `wait-text "打卡成功"` 这一步。
只看「点到了」不算成功 —— 网络超时、接口报错都可能让打卡失败。

---

### 4. 定时抢券 / 限量预约 ⭐⭐⭐

```bash
# 蹲点：等到整点再点
while [ "$(date +%H%M%S)" \< "100000" ]; do sleep 0.3; done
phone.sh tap-text "立即领取"
phone.sh wait-text "领取成功" 5
```

**诚实提醒：** 这类操作有被平台判定为异常的风险，且部分平台禁止。
本工具只提供技术能力，**用不用、合不合规由你判断**。

---

## 开发与测试

### 5. App 回归测试，不写一行 Java ⭐⭐

**痛点：** 只想验证「改完 UI 后，主要流程还能不能走通」，
但要为此学 Appium、起 Server、写定位器，太重。

```bash
golden() {
  phone.sh app com.example.app
  phone.sh wait-text "首页" 15
  phone.sh tap-text "我的"
  phone.sh wait-text "个人中心" 5
  phone.sh shot "/tmp/case1.jpg"
}

check() {
  phone.sh shot "/tmp/current.jpg"
  magick compare -metric RMSE "/tmp/golden/$1.jpg" /tmp/current.jpg null: 2>&1
}
```

RMSE 小于 0.05 视为通过。首次跑出来的图作为基准（golden）。

**适用：** 中小团队、个人开发者、非 UI 测试岗的人想加一道保险。

---

### 6. 多机型兼容性验证 ⭐⭐⭐

```bash
for serial in $(phone.sh devices | awk '{print $1}'); do
  echo "=== $serial ==="
  PHONE_SERIAL="$serial" phone.sh app com.example.app
  PHONE_SERIAL="$serial" phone.sh wait-text "首页" 20
  PHONE_SERIAL="$serial" phone.sh shot "/tmp/compat-$serial.jpg"
done
```

---

### 7. 启动耗时统计 ⭐

```bash
phone.sh logcat-clear
phone.sh app com.example.app
sleep 3
phone.sh logcat | grep -oE "Displayed com\.example\.app/[^[:space:]]+: \+[0-9]+ms"
```

---

### 8. 崩溃复现与取证 ⭐⭐

```bash
phone.sh logcat-clear
# ... 用 tap-text / swipe 复现步骤 ...
phone.sh logcat | grep -A 30 "FATAL EXCEPTION"
phone.sh shot /tmp/crash.jpg
```

---

## 生活与照看

### 9. 远程帮爸妈处理手机问题 ⭐

**痛点：** 长辈手机上弹个广告、误开个设置，电话里说十遍也说不清。

手机放家里，接电 + Tailscale，你在任何地方：

```bash
export PHONE_MODE=tailscale
phone.sh shot --small /tmp/mom.jpg     # 先看屏幕长什么样
phone.sh tap-text "关闭"                 # 广告弹窗，直接点掉
phone.sh tap-text "允许"                 # 帮她点授权
```

**比远程桌面好在哪：** 不用教她怎么点、不用她操作，
你直接看到屏幕、直接操作，她什么都不用做。

> 前提是长辈知情并同意。这毕竟是她的手机。

---

### 10. 睡前自动关屏 / 勿扰 ⭐

```bash
# 22:30 关屏
30 22 * * * /path/to/phone.sh shell "input keyevent KEYCODE_SLEEP"

# 07:00 点亮
0 7 * * * /path/to/phone.sh wake
```

---

## AI Agent 集成

### 11. 让 Agent 真的能"用"手机 ⭐⭐

这是本项目的初衷。给 Agent 的系统提示里写上：

```
你可以用 phone.sh 操作手机。工作循环：
1. phone.sh ui          —— 看当前界面
2. phone.sh tap-text "<目标>"  —— 点
3. phone.sh wait-text "<预期结果>"  —— 验证
失败时读报错，换策略（滚动、返回、用 resource-id）。
```

实测有效的技巧：

- **先在 `ui` 输出里找到目标文字的确切写法**，不要猜（中文全角/半角、空格）
- **用 `--exact`** 避免「保存」点到「保存并退出」
- **`scroll-to` 比反复 swipe 更可靠**
- **`shot` 只用来给用户看结果**，不要用截图做判断依据（OCR 不稳定）

---

### 12. 语音口令 → 手机操作 ⭐⭐⭐⭐

语音转文字 → 让 LLM 翻译成 `phone.sh` 命令 → 执行。
适合「帮我把刚才那条消息转发给张三」这类场景，
但要注意**聊天内容是隐私红线**，涉及时要格外小心。

---

## 还没人做，但可行

这些是思路，方向可行但没实测过。欢迎认领：

| 想法 | 思路 |
| --- | --- |
| **App 沙盒数据备份** | `pull /sdcard/Android/data/<pkg>/` 定时快照 |
| **设备健康巡检** | `dumpsys battery` + `dumpsys meminfo` 定时采集，画曲线 |
| **自动填写表单** | `ui` 读出输入框 → 逐个 `tap` + `text` |
| **手机农场** | 多台设备 + `PHONE_SERIAL` 并行跑 |
| **无障碍辅助** | 给视障用户做语音播报界面内容 |
| **竞品监控** | 定时截图另一个 App 的价格页做对比 |

---

## 不要做的事

以下场景听起来可行，但**不该做**，本项目也不为它们提供便利：

- ❌ 绕过锁屏、破解密码
- ❌ 读取他人的聊天记录、相册、短信
- ❌ 批量注册账号、刷单、虚假流量
- ❌ 任何违反 App 服务条款的行为

技术能力和使用边界是两件事。这条线请自己守住。

---

<div align="center">
<a href="../README.md">⬅ 回到 README</a>
</div>
