# USB 接入（最稳，老机型唯一解）

> 适合：Android 10 及以下、无线调试打不开、网络环境复杂、或者就是喜欢插线。
> 有线的延迟最低、最不容易掉，做**长时间录制**和**稳定性要求高的自动化**首选。

---

## 第一步：准备一根「能传数据」的线

这一步坑最多。**很多附赠线只能充电，不传数据。**

怎么判断手上的线行不行：

- 插上电脑后，手机通知栏出现「正在通过 USB 充电」的提示 → **可以再往下试**
- 如果手机只显示充电、电脑毫无反应，**换一根线**（原装线通常可以）

---

## 第二步：手机上打开 USB 调试

1. 设置 → 关于手机 → 连续点 **版本号** 7 次，开启开发者选项
2. 设置 → 系统 → 开发者选项 → 打开 **USB 调试**
3. （小米/Redmi 额外建议）同一页面打开 **USB 安装**，否则装 APK 会被拦

---

## 第三步：插线并选择「传输文件」

1. 用数据线把手机连到电脑
2. 手机通知栏下划，找到 USB 用途通知，点开
3. 选择 **传输文件 / MTP**

> 选「仅充电」时，adb 通常连不上。这一步不能省。

---

## 第四步：在手机上允许调试

电脑第一次连这台手机时，手机会弹出：

> **允许 USB 调试吗？**
> 计算机 RSA 密钥指纹：xx:xx:xx...

- ✅ 勾选 **一律允许使用这台计算机进行调试**
- 点 **允许**

**如果没有弹出这个框**，说明电脑没被识别为调试主机，试：

```bash
adb kill-server
adb start-server
adb devices
```

然后重新拔插数据线。

---

## 第五步：验证

```bash
phone.sh setup
```

输出里应该看到：

```
【3/4】接口与链路
  ✓ USB 设备可用: <SERIAL>
```

或者直接：

```bash
phone.sh devices
```

```
SERIAL                       STATE        TYPE   MODEL
<SERIAL>                      device       usb    <YOUR_DEVICE>
```

`device` 是正常状态。如果是 `unauthorized`，回到第四步看手机屏幕；
如果是 `offline`，执行 `adb kill-server && adb start-server`。

---

## 进阶：把 USB 连接变成无线

USB 连上之后，可以让手机开放一个 TCP 调试端口，之后就不用插线了。

```bash
phone.sh openport
```

它会：

1. 找到 USB 连着的手机
2. 执行 `adb tcpip 5555`
3. 探测手机的 Tailscale / 局域网 IP 并记住

然后拔掉线：

```bash
phone.sh connect
phone.sh screen
```

### 这个方式能撑过重启吗？

**不能。** 这和无线调试是同一个道理：

| 操作 | 重启后 |
| --- | --- |
| `adb tcpip 5555` | 失效，端口没了 |
| 无线调试配对 | 失效，需要重新配对 |
| USB 连接 | 仍然可用（但要重新授权，除非勾了「一律允许」） |

重启后想恢复无线：

```bash
phone.sh recover     # 提示你插一次线，然后自动重开端口
```

> **为什么不做成开机自启？**
> 因为那需要在手机端常驻一个 root 权限的服务，或者改系统设置。
> 这个工具刻意不碰这些 —— 安全性优先于便利性。

### 端口 5555 的安全说明

`5555` 是 adb 的传统 TCP 端口。很多人担心它危险，实际情况是：

- Android 的 adbd **强制要求 RSA 认证**（`ro.adb.secure=1`）
- 没有在手机上点过「允许」，任何连接都会被拒绝
- 所以**局域网内**开着它，风险很低

但**绝对不要**把它端口转发到公网。想在外网用，请走
[Tailscale](setup-tailscale.md)，那条路是加密的私有网络。

---

## 常见问题速查

| 现象 | 原因 | 解法 |
| --- | --- | --- |
| `adb devices` 完全没输出 | 线只能充电 / 没选 MTP / 没开 USB 调试 | 换线、选传输文件、开调试 |
| `unauthorized` | 手机没点允许 | 看手机屏幕点允许；或 `adb kill-server` 后重插 |
| `offline` | 连接假死 | `adb kill-server && adb start-server` |
| 连上但操作无反应 | 屏幕锁着 | 先在手机上解锁；`phone.sh wake` 只能亮屏 |
| 装 APK 报 `INSTALL_FAILED_USER_RESTRICTED` | 小米/OPPO 限制 | 开发者选项 → 打开「USB 安装」（小米还需登录账号） |
| 多台设备时命令打到错的手机 | 没指定目标 | `PHONE_SERIAL=<序列号> phone.sh ...` |

---

## 下一步

- 不想插线了 → [无线调试](setup-wireless.md)
- 想在外网控手机 → [Tailscale](setup-tailscale.md)
- 卡住了 → [故障排查](troubleshooting.md)
