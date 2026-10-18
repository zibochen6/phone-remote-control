<div align="center">

<img src="assets/banner.png" width="100%" alt="phone-remote-control" />

# phone-remote-control

**Let your own AI agent drive your Android phone.**

No cable, no public IP, no root. One command turns a phone into an interface an agent can read and tap.

[![License: MIT](https://img.shields.io/badge/License-MIT-2ea44f.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-1f6feb.svg)](#requirements)
[![Android](https://img.shields.io/badge/Android-8.0%2B-3ddc84.svg)](#supported-phones)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-ff69b4.svg)](CONTRIBUTING.md)

[Quick start](#quick-start) · [Why not scrcpy?](#why-not-scrcpy--appium--uiautomator) · [Commands](#command-cheatsheet) · [Use cases](docs/use-cases.md) · [FAQ](#faq) · [中文](README.md)

</div>

---

## What this is

A shell script plus an Agent Skill that turns the Android UI into **structured, verifiable** targets.

```bash
phone.sh ui                        # read what's on screen
phone.sh tap-text "WLAN"           # tap by text, don't guess coordinates
phone.sh wait-text "Connected" 15  # confirm the action actually worked
```

**The core problem it solves:** agents that drive phones by coordinates are fragile.
Hardcoded `(540, 1200)` breaks when someone changes their font size, system language,
or upgrades their phone — the script is silently wrong, and you find out weeks later.

Text doesn't move. `tap-text` reads the accessibility tree, finds the word, and taps
its real bounds — then `wait-text` confirms the result appeared.

<div align="center">
  <img src="assets/screens/cli-demo.png" width="820" alt="CLI demo" />
</div>

---

## Why not scrcpy / Appium / UiAutomator

All good tools, but different goals. This project does **not** replace them:

| | **This project** | scrcpy | Appium | Raw UiAutomator |
| --- | --- | --- | --- | --- |
| Purpose | Agent/script operation layer | Human screen mirroring | Professional UI test framework | Low-level test API |
| Tap by text | ✅ built in | ❌ mouse only | ✅ but you write locators | ⚠️ DIY |
| Verify after tapping | ✅ `wait-text` | ❌ eyeballs | ✅ | ⚠️ DIY |
| Time to first tap | ✅ one script | ✅ | ❌ server + client + driver | ❌ Java + compile |
| Dependencies | adb (+python3) | adb | Node/Java + Appium Server | Android SDK |
| Learning curve | ~10 commands | Low | High | High |
| Agent-friendly | ✅ plain CLI, parseable output | ❌ GUI app | ⚠️ needs wrapping | ❌ needs wrapping |

**In one line:** if you want an AI or a script to "tap this button and confirm it worked",
this is built for exactly that. If you want to play with your phone by mouse, use scrcpy.

---

## Quick start

### 1. Install dependencies

```bash
# macOS
brew install --cask android-platform-tools && brew install python3

# Ubuntu / Debian
sudo apt install android-tools-adb python3
```

### 2. Let the phone be controlled

**Android 11+ (recommended, no cable)**

1. Settings → About phone → tap "Build number" 7 times
2. Settings → System → Developer options → enable **Wireless debugging**
3. Tap "Pair device with pairing code" and **leave the dialog open**

**Android 10 and below (use a cable)**

1. Enable Developer options the same way, turn on **USB debugging**
2. Plug in a cable, choose **File transfer** on the phone
3. Tap "Allow USB debugging?" → check "Always allow" → Allow

### 3. Connect

```bash
phone.sh pair        # wireless debugging (recommended)
# or
phone.sh setup       # auto-detect and tell you the next step
```

### 4. Verify

```bash
phone.sh status      # tools / device / screen / foreground app
phone.sh screen      # screen state
```

Seeing `✓ connected` means you're done.

<div align="center">
  <img src="assets/screens/battery.png" width="240" alt="Read the UI" />
  <img src="assets/screens/more-settings.png" width="240" alt="Tap by text" />
  <img src="assets/screens/alarm.png" width="240" alt="Any app" />
  <br/>
  <sub>↑ Every screenshot here was captured by this project and auto-redacted</sub>
</div>

> **Full step-by-step guides** (written for people who have never used adb):
> [Wireless](skills/phone-remote-control/references/setup-wireless.md) ·
> [USB](skills/phone-remote-control/references/setup-usb.md) ·
> [Remote / Tailscale](skills/phone-remote-control/references/setup-tailscale.md)
> *(guides are in Chinese, since that's where most learners start)*

---

## Three ways to connect

| | Wireless debugging | USB cable | Tailscale |
| --- | --- | --- | --- |
| **Works on** | Android 11+ | All devices | Phone on another network |
| **Cable needed** | ❌ | ✅ | Only once |
| **App needed** | ❌ | ❌ | One on phone, one on computer |
| **Across networks** | ❌ same Wi-Fi | ❌ | ✅ even on 4G |
| **After reboot** | Re-enable + re-pair | Just plug in | Plug in once to restore the port |

**Can't decide?** Run `phone.sh setup` — it inspects your phone and tells you which path to take.

> **On "network tunneling"**
> The classic answer is a public IP plus router port forwarding — dangerous
> (you're hanging your keys on the internet) and painful (beg your ISP).
> We recommend **Tailscale** instead: an encrypted private network where your two
> devices behave as if they're on the same LAN, **with no public port opened**.

---

## Command cheatsheet

| Read | Act | Wait / locate |
| --- | --- | --- |
| `shot` screenshot | `tap-text "text"` tap by text | `wait-text "text" 15` wait for it |
| `ui` on-screen text | `tap X Y` tap by coordinate | `scroll-to "text"` scroll until found |
| `nodes` full node tree | `swipe X1 Y1 X2 Y2` swipe | `find "text"` locate a node |
| `screen` state | `key HOME` key event | `nodes --json` machine-readable |

```bash
phone.sh app com.android.settings   # launch an app
phone.sh text "hello"               # type text (ASCII)
phone.sh record 10 /tmp/a.mp4       # screen record
phone.sh mirror --bg                # background mirror (needs scrcpy)
phone.sh doctor                     # run this when it won't connect
phone.sh shell "dumpsys battery"    # arbitrary shell
```

Full command reference + 7 recipes → [Cookbook](skills/phone-remote-control/references/cookbook.md)

---

## Requirements

| | Requirement |
| --- | --- |
| OS | macOS or Linux (Windows via WSL2) |
| adb | **required** |
| python3 | strongly recommended (`tap-text` needs it) |
| scrcpy | optional, only for `mirror` |
| tesseract / magick | optional, only for privacy scanning |

**Supported phones:** Android 8.0+ (wireless debugging needs 11+).
Verified on MIUI 14 / Android 12. Huawei, OPPO, vivo, Samsung should work —
reports welcome.

---

## Deliberate limitations

This tool intentionally **doesn't** do certain things. These are features, not bugs:

| Not supported | Why |
| --- | --- |
| ❌ Auto-reconnect after reboot | Needs root or a system exploit. We'd rather you plug in a cable |
| ❌ Exposing port 5555 publicly | adb has RSA auth, but it shouldn't be internet-scannable |
| ❌ Bypassing the lock screen | That's your security boundary, not a feature |
| ❌ Cloud relay | Your data stays on your own devices and network |
| ❌ Reading your gallery / SMS / chats | See [Privacy](#privacy) |

**Known limitations (stated honestly):**

- Continuously animating screens (stopwatch, world clock) never reach an idle state,
  so `uiautomator` can't dump them — `ui`/`tap-text` fail with a clear message
  instead of silently doing the wrong thing. Use screenshots and coordinates there.
- Banking apps and some video apps block UI inspection. Nothing can be done.
- Chinese input requires an extra IME (Android's `input text` is ASCII-only).
- Wireless debugging **must be re-paired after every reboot** — that's Android's design.

---

## Privacy

**This is the part we take most seriously.**

- 🔒 **All data stays between your own devices.** No cloud, no telemetry, no reporting.
- 🔒 `~/.phone-remote.conf` is created with `600` permissions and is gitignored.
- 🔒 The repo contains **no** real device info — model, serial, IP, and SSID are placeholders.
- 🔒 Every screenshot here was auto-redacted **and** manually reviewed before publishing.

```bash
# Check a screenshot for phone numbers / IPs / SSIDs / serials / national IDs
scripts/privacy_scan.sh shot.jpg

# Auto-blackout sensitive text (OCR-driven, with manual region support)
scripts/privacy_scan.sh --auto-mask shot.jpg safe.jpg --statusbar
```

> ⚠️ **Auto-masking is not a guarantee.** OCR can miss text (e.g. white-on-color).
> Treat it as one extra gate, and always look at the image yourself before publishing.

---

## For agents

The repo is itself a loadable Skill:

```
skills/phone-remote-control/
├── SKILL.md                      # instructions the agent reads
├── references/                   # human-facing guides + troubleshooting
└── scripts/
    ├── phone.sh                  # main script
    ├── ui_parse.py               # accessibility tree parser
    └── privacy_scan.sh           # privacy scan / redaction
```

Drop it into your agent's skills directory. `SKILL.md` spells out the
**privacy red lines** the agent must respect and the **destructive actions**
it must confirm with the user first.

---

## FAQ

<details>
<summary><b>Does it support iPhone?</b></summary>

**No, and it never will.** iOS has no sanctioned way for external programs to
drive the UI — that's the whole point of its security model. Jailbreak-based
approaches are unstable and risky, so we don't.

Android is open, which is exactly what makes it automatable.
</details>

<details>
<summary><b>It stops working after a reboot. Is that normal?</b></summary>

**Yes.** Neither wireless debugging nor `adb tcpip 5555` survive a reboot —
that's an Android design decision.

- Wireless → re-enable it and run `phone.sh pair`
- USB-to-wireless → plug in once and run `phone.sh recover`

We don't ship "auto-reconnect on boot" because that requires root.
</details>

<details>
<summary><b>Is it safe? Can someone else connect to my phone?</b></summary>

- adb enforces RSA authentication (`ro.adb.secure=1`); connections without a
  phone-side approval are rejected
- Wireless debugging picks a random port that dies on reboot
- Tailscale is an end-to-end encrypted private network exposing zero public ports

**Your part:** don't leave wireless debugging on in public Wi-Fi, and never
forward port 5555 to the internet.
</details>

<details>
<summary><b>Why not just use OCR / vision models to tap?</b></summary>

You can, but it's neither precise nor verifiable. A vision model may "look like"
it tapped correctly while landing dozens of pixels off, and **it can't confirm
the tap did anything**.

`uiautomator` reads real system state, so you can read it back to verify.
That's why we prefer the accessibility tree, and use OCR only for privacy scanning.
</details>

<details>
<summary><b>Multiple phones at once?</b></summary>

Yes:

```bash
PHONE_SERIAL=aaa111 phone.sh tap-text "OK"
PHONE_SERIAL=bbb222 phone.sh tap-text "OK"
```
</details>

---

## Roadmap

- [x] Wireless debugging / USB / Tailscale
- [x] Tap by text, wait, scroll-to
- [x] Six-layer `doctor` diagnostics
- [x] Privacy scanning and auto-redaction
- [ ] **Web UI** (view and tap from a browser)
- [ ] Change detection for vision-only mode
- [ ] Automatic recording segmentation and stitching
- [ ] Native Windows support (WSL2 for now)
- [ ] More device reports

Want something? [Open an issue](https://github.com/USER/phone-remote-control/issues).

---

## Contributing

PRs welcome! Especially:

- **Testing on other devices** (Huawei / OPPO / vivo / Samsung / Pixel)
- Adding your use case
- Reporting the pitfalls you hit

Read [CONTRIBUTING.md](CONTRIBUTING.md) first.
**Always run `privacy_scan.sh` before committing a screenshot.**

---

## License

[MIT](LICENSE) © phone-remote-control contributors

---

<div align="center">

**If this saved you an afternoon of setup, please leave a ⭐**

It helps the next person who needs "let an AI drive my phone" find this repo.

[⬆ Back to top](#phone-remote-control)

</div>
