# 异地控制：用 Tailscale 在外网操作家里的手机

> **目标场景：** 手机放在家里，你在公司 / 在外地，想远程看它、操作它。
> 比如：远程帮爸妈关掉手机上的弹窗广告、随时看家里的手机电量、
> 在公司给家里的手机跑自动化任务。

---

## 先搞清楚三个词（30 秒版）

你可能听过「内网穿透」「端口映射」「公网 IP」，听起来很吓人。其实只需要理解：

| 词 | 大白话 |
| --- | --- |
| **局域网** | 你家里 Wi-Fi 内部，设备之间能互相访问 |
| **公网 IP** | 整个互联网上唯一地址，运营商**基本不给个人**了 |
| **内网穿透** | 让外面的设备能"钻进"你家局域网 —— 这就是我们要解决的问题 |

**传统做法**是在路由器上做端口转发 + 申请公网 IP + 配 DDNS + 搞 HTTPS 证书。
**又危险**（等于把你家大门钥匙挂到网上）、**又麻烦**（还得求运营商给公网 IP）。

**Tailscale 的做法完全不同：** 它在你所有设备之间建一张**加密的私有虚拟局域网**。
每台设备拿到一个 `100.x.x.x` 的虚拟 IP，彼此就像坐在同一个路由器下面。

> **一句话：** 不用公网 IP、不用改路由器、不用开任何端口，两台设备秒变"同一个 WiFi"。

---

## 为什么这套方案是安全的？

这是它比端口转发强得多的关键：

| 对比项 | 端口转发（传统做法） | Tailscale |
| --- | --- | --- |
| 谁可以连进来 | **整个互联网**（扫描器会找到你） | **只有你自己账号下的设备** |
| 传输加密 | 要自己配 TLS 证书 | WireGuard 端到端加密，默认就有 |
| 路由器配置 | 需要，且各品牌不一样 | **完全不需要** |
| 域名 / DDNS | 需要 | 不需要 |
| 暴露端口 | 必须暴露 | **一个都不暴露** |

底层用 WireGuard（业界公认最现代的 VPN 协议），开源、经过广泛审计。

---

## 第一步：在电脑上装 Tailscale

**macOS**

```bash
brew install --cask tailscale
```

或者从 [tailscale.com/download](https://tailscale.com/download) 下载 App。
安装后打开，菜单栏会出现 Tailscale 图标。

**Linux**

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

**Windows**

从 [tailscale.com/download](https://tailscale.com/download) 下载安装包，一路下一步。

---

## 第二步：登录（建议用同一个账号）

电脑上点 Tailscale 图标 → **Log in**，选择用 Google / Microsoft / GitHub / 邮箱登录。

> **关键：手机和电脑必须登录同一个账号。**
> 这是唯一能让两台设备互相看见的条件。

免费额度：个人用 100 台设备，足够了。

---

## 第三步：在手机上装 Tailscale

1. 手机应用商店搜 **Tailscale**（Google Play / App Store），或从官网下 APK
2. 打开 App，**登录和电脑同一个账号**
3. 点连接开关，允许创建 VPN 连接

> **⚠️ 小米 / Redmi / OPPO 用户注意**
> 如果手机装了 Clash、Surge 这类代理 App，它们会抢占系统的 VPN 槽位，
> 导致 Tailscale 无法启动。**先关掉代理 App 再开 Tailscale。**

---

## 第四步：确认两台设备互相看得见

在电脑上：

```bash
tailscale status
```

应该能看到类似：

```
100.x.x.x   <YOUR_PHONE>        your@account   android  active; direct
100.x.x.x   your-laptop         your@account   macOS    -
```

- `active` = 在线
- `offline` = 手机端 Tailscale 掉线了（回去看手机 App）
- 看不到手机 = 没登录同一账号 / 手机没开 VPN

拿到手机的主机名（上面第二列），记下来：

```bash
export PHONE_HOST="<YOUR_PHONE>"     # 填你手机上看到的名字
```

---

## 第五步：让手机开放调试端口（需要插一次线）

Tailscale 只解决「能连通」，还要让手机上的 adb 监听 TCP。

**插上 USB 线**，确认 `phone.sh devices` 能看到手机，然后：

```bash
phone.sh openport
```

输出：

```
→ USB 设备 <SERIAL>：开启 TCP 端口 5555
    restarting in TCP mode port: 5555
✓ 手机 Tailscale IP: 100.x.x.x
→ 下一步：拔掉线，运行  PHONE_MODE=tailscale phone.sh connect
```

拔掉线，然后：

```bash
export PHONE_MODE=tailscale
phone.sh connect
phone.sh screen
```

如果看到屏幕状态，就成功了。**把它写进配置，以后不用再设：**

```bash
phone.sh shell getprop ro.product.model   # 确认真的连上了
```

```bash
# 写入配置文件，永久生效
echo "MODE=tailscale" >> ~/.phone-remote.conf
echo "TS_HOST=<YOUR_PHONE>" >> ~/.phone-remote.conf
```

> **不方便插线？** 用[无线调试](setup-wireless.md) 先在局域网里连上，
> 再执行 `phone.sh openport`（它会自动找当前连接的设备）。

---

## 第六步：验证真的能跨网络

**测试方法：** 把手机切到**移动数据**（关掉 Wi-Fi），电脑连**手机热点以外的网络**。

```bash
phone.sh doctor
```

```
【3】Tailscale
  主机名: <YOUR_PHONE>  状态: active
【4】连接与操作面
  ✓ 目标: 100.x.x.x:5555
```

能看到 `active` 和 `✓`,就说明跨网络通了。

仓库里还带了一个自动验证脚本：

```bash
./skills/phone-remote-control/scripts/verify-cross-network.sh
```

它会逐层检查：Tailscale 节点 → ping → TCP 端口 → adb → 界面，并指出断在哪一层。

---

## 重启后怎么办？

**`adb tcpip 5555` 不跨重启**，这是 Android 的行为。手机重启后：

```bash
phone.sh recover
```

它会告诉你「需要插一次线」，插上线后自动重开端口。

### 想全自动？这里有个诚实的说明

理论上可以做到开机自动重连，常见思路：

1. **手机端**用 Tasker / MacroDroid 监听开机，自动执行 `setprop service.adb.tcp.port 5555`
   —— **需要 root**，普通用户做不到
2. **用无线调试代替**：Android 11+ 的无线调试端口每次随机，但可以通过
   `adb mdns services` 自动发现，配合一个电脑端守护进程定时重连
   —— **不需要 root**，但手机端仍需手动重开无线调试开关

我们**没有**内置自动开机重连，原因是它要么需要 root（拒绝）、
要么靠系统漏洞（不可靠且会被版本更新打掉）。

`phone.sh recover` 把恢复成本压到了「插一次线」，这是目前最诚实的平衡点。

---

## 安全清单（照着确认一遍）

- ✅ Tailscale 账号开了 **两步验证**
- ✅ 手机和电脑登录的是**同一账号**，不要把设备共享给不信任的人
- ❌ **不要**在路由器上把 5555 端口转发到公网
- ❌ **不要**在公共 Wi-Fi 下开着无线调试
- ✅ 不用的时候 `phone.sh disconnect`，或直接关掉手机上的 Tailscale
- ✅ 定期在 Tailscale 后台清理不再使用的设备授权

---

## 和「买内网穿透服务」比怎么样

| | Tailscale | 商业内网穿透（frp 服务商 / 花生壳等） |
| --- | --- | --- |
| 费用 | 个人免费（100 设备） | 通常按月收费，带宽还要加钱 |
| 加密 | 端到端 WireGuard | 取决于服务商，多数只加密到服务商 |
| 速度 | P2P 直连，走你自己网络 | 走服务商中转，带宽受限 |
| 隐私 | 数据不经过第三方 | 数据经过第三方服务器 |
| 部署难度 | 装完登录就行 | 要配隧道、域名、证书 |

**结论：个人用途，Tailscale 基本全面胜出。**

---

## 卡住了

→ [故障排查](troubleshooting.md)，里面有 Tailscale 专门的分节。
