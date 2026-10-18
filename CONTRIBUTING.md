# 贡献指南

感谢你愿意参与！这个项目的目标很朴素：
**让任何一个想让 AI 操作手机的人，能在 10 分钟内跑通。**

任何能让这个目标更近一步的贡献都欢迎。

---

## 最需要的贡献

按价值排序：

### 1. 新机型实测反馈（最有价值）

我们只在 **MIUI 14 / Android 12** 上完整验证过。
华为、OPPO、vivo、三星、Pixel 上很可能有差异 —— 尤其是：

- `uiautomator dump` 的行为
- 无线调试的配对流程
- 后台进程是否被系统杀掉

**怎么反馈：** 开 issue，附上 `phone.sh doctor` 的输出。
**注意：** 提交前把 IP、型号、序列号、Wi-Fi 名替换成占位符。

### 2. 应用案例

你用它做了什么？写在 [docs/use-cases.md](docs/use-cases.md) 里，
格式照抄已有的案例。真实案例比任何宣传都有说服力。

### 3. 文档改进

看某个地方卡住了？那就是文档的问题，不是你的问题。
告诉我们在哪一步卡住，或者直接改。

### 4. Bug 修复与功能

见下面的流程。

---

## 开发环境

```bash
git clone https://github.com/USER/phone-remote-control.git
cd phone-remote-control
```

依赖：

```bash
# macOS
brew install --cask android-platform-tools
brew install python3 scrcpy tesseract tesseract-lang imagemagick ffmpeg shellcheck

# Ubuntu
sudo apt install android-tools-adb python3 scrcpy tesseract-ocr tesseract-ocr-chi-sim imagemagick ffmpeg shellcheck
```

---

## 代码结构

```
skills/phone-remote-control/
├── SKILL.md                 # Agent 读的说明书（改它等于改 Agent 的行为）
├── references/*.md          # 给人读的教程
└── scripts/
    ├── phone.sh             # 主脚本，POSIX 风格 bash
    ├── ui_parse.py          # 控件树解析（给 phone.sh 调用）
    └── privacy_scan.sh      # 隐私扫描 / 打码
```

**设计原则：**

1. **不引入新依赖，除非真的必要** —— 每多一个依赖，就多一批人装不上
2. **失败要有可行动的信息** —— 不要只说「失败」，要说「为什么 + 怎么办」
3. **破坏性操作默认关闭** —— 例如 `reboot` 需要显式设 `PHONE_ALLOW_REBOOT=1`
4. **不假设设备信息** —— 脚本里不能出现具体型号、序列号、IP

---

## 提交前检查

```bash
# 1. 语法
bash -n skills/phone-remote-control/scripts/phone.sh
bash -n skills/phone-remote-control/scripts/privacy_scan.sh
shellcheck skills/phone-remote-control/scripts/*.sh

# 2. Python
python3 -m py_compile skills/phone-remote-control/scripts/ui_parse.py

# 3. 帮助能跑
bash skills/phone-remote-control/scripts/phone.sh help

# 4. ⚠️ 隐私扫描：截图和文档里不能有真实设备信息
bash skills/phone-remote-control/scripts/privacy_scan.sh assets/screens/*.png
```

### 隐私检查清单（硬性要求）

提交任何图片或日志前，确认里面**没有**：

- [ ] 真实手机型号 / 序列号
- [ ] 真实 IP（包括 `192.168.x.x`、`100.x.x.x`）
- [ ] 真实 Wi-Fi 名称
- [ ] 手机号 / 邮箱 / 姓名 / 头像
- [ ] 具体的日期时间（状态栏）
- [ ] 聊天记录、短信、相册内容
- [ ] 账号昵称、余额、订单

**自动扫描只能拦一部分。提交前请自己再看一眼那张图。**

---

## 提交 PR

```bash
git checkout -b fix/wireless-pair-on-huawei
# ... 改代码 ...
git commit -m "fix: 华为设备无线配对端口解析失败"
git push origin fix/wireless-pair-on-huawei
```

**Commit 信息格式**（Conventional Commits）：

```
feat: 新增 xxx 命令
fix: 修复 xxx 场景下的崩溃
docs: 补充 xxx 说明
refactor: 重构 xxx
test: 补充 xxx 测试
```

**PR 里请写清楚：**

- 问题是什么（在什么机型/系统上复现）
- 改了什么
- 怎么验证的（贴命令和输出）
- 如果改了行为，说明为什么这么改

---

## 行为准则

- 友善、就事论事
- 不评判提问者的水平 —— 很多人是第一次接触 adb
- 不接受任何用于侵犯他人隐私、绕过安全机制、刷量的功能请求

---

<div align="center">
<a href="README.md">⬅ 回到 README</a>
</div>
