#!/usr/bin/env python3
"""检查文档：本地链接存在 + 站内锚点有效。

GitHub 的锚点规则：标题转小写、去掉标点和反引号、空格转连字符、
保留中文和连字符。这里复刻它，让 CI 能提前发现点不动的导航。
"""
import pathlib
import re
import sys


def gh_anchor(title):
    s = title.strip().lower()
    s = s.replace("`", "")
    s = re.sub(r"[^\w\u4e00-\u9fff\- ]", "", s)
    return s.replace(" ", "-")


bad = []
for md in sorted(pathlib.Path(".").rglob("*.md")):
    if ".git" in md.parts:
        continue
    text = md.read_text(errors="ignore")
    base = md.parent

    anchors = set()
    for line in text.splitlines():
        m = re.match(r"^(#{1,6})\s+(.*)", line)
        if m:
            anchors.add(gh_anchor(m.group(2)))

    for m in re.finditer(r"\[[^\]]*\]\(([^)]+)\)", text):
        link = m.group(1).strip()
        if link.startswith(("http://", "https://", "mailto:")):
            continue
        if link.startswith("#"):
            if link != "#" and link[1:] not in anchors:
                bad.append(f"{md}: 坏锚点 {link}")
            continue
        target = link.split("#")[0]
        if target and not (base / target).exists():
            bad.append(f"{md}: 坏链接 {link}")

if bad:
    print("✗ 文档检查失败：")
    for b in bad:
        print("  " + b)
    sys.exit(1)
print("✓ 文档链接与锚点全部有效")
