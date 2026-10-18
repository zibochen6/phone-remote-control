#!/usr/bin/env python3
"""解析 uiautomator dump 的 XML（从 stdin 读入）。

被 phone.sh 调用，不直接给用户使用。

模式：
  text                 每行输出一个非空 text（无 text 时用 content-desc）
  tsv [--all]          制表符分隔：text, desc, id, class, bounds, flags
                       （默认跳过 text/desc/id 全空的布局节点；--all 全输出）
  json                 每行一个 JSON 对象（text/desc/id/class/bounds/flags…）
  find-text NEEDLE     在 text/content-desc 中查找，输出匹配的 tsv 行
  find-id NEEDLE       在 resource-id 中查找，输出匹配的 tsv 行
  pick-text NEEDLE     选一个最值得点击的匹配节点，输出单行 tsv：x y text …
  pick-id NEEDLE       同上，按 resource-id 匹配
可选参数：--exact（精确匹配而非包含）、--all（tsv 输出全节点）

退出码：0 正常；1 无匹配；2 解析失败；3 用法错误
"""
import json
import sys
import xml.etree.ElementTree as ET


def die(msg, code=2):
    print(msg, file=sys.stderr)
    sys.exit(code)


def parse_bounds(s):
    try:
        n = [int(t) for t in s.replace("[", " ").replace("]", " ").replace(",", " ").split()]
        if len(n) == 4:
            return n
    except Exception:
        pass
    return None


def esc(s):
    return (s or "").replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")


def make_row(node):
    a = node.attrib
    b = parse_bounds(a.get("bounds", "")) or [0, 0, 0, 0]
    text = a.get("text", "")
    desc = a.get("content-desc", "")
    rid = a.get("resource-id", "")
    cls = a.get("class", "")
    flags = ""
    if a.get("clickable") == "true":
        flags += "c"
    if a.get("focused") == "true":
        flags += "f"
    if a.get("scrollable") == "true":
        flags += "s"
    if a.get("checkable") == "true":
        flags += "k1" if a.get("checked") == "true" else "k0"
    if a.get("selected") == "true":
        flags += "S"
    if a.get("password") == "true":
        flags += "p"
    if a.get("enabled") != "true":
        flags += "-"
    clickable = a.get("clickable") == "true" and a.get("enabled") != "false"
    return {
        "x": b[0], "y": b[1], "x2": b[2], "y2": b[3],
        "bounds": b, "text": text, "desc": desc, "id": rid, "class": cls,
        "flags": flags, "clickable": clickable,
        "scrollable": a.get("scrollable") == "true",
        "enabled": a.get("enabled") != "false",
    }


def tsv_line(r):
    return "\t".join([
        esc(r["text"]), esc(r["desc"]), r["id"], r["class"],
        f'{r["x"]},{r["y"]},{r["x2"]},{r["y2"]}', r["flags"],
    ])


def main():
    args = sys.argv[1:]
    if not args:
        die("usage: ui_parse.py MODE [NEEDLE] [--exact] [--all]", 3)
    mode = args[0]
    rest = args[1:]
    exact = "--exact" in rest
    all_rows = "--all" in rest
    needles = [a for a in rest if not a.startswith("--")]
    needle = needles[0] if needles else ""
    if mode in ("find-text", "find-id", "pick-text", "pick-id") and not needle:
        die("NEEDLE required", 3)

    try:
        root = ET.fromstring(sys.stdin.read())
    except Exception as e:
        die(f"UI XML 解析失败: {e}")

    rows = [make_row(n) for n in root.iter("node")]

    if mode == "text":
        for r in rows:
            t = r["text"].strip() or r["desc"].strip()
            if t:
                print(esc(t))
        return

    if mode == "tsv":
        for r in rows:
            if not all_rows and not (r["text"] or r["desc"] or r["id"]):
                continue
            print(tsv_line(r))
        return

    if mode == "json":
        for r in rows:
            print(json.dumps({
                "text": r["text"], "desc": r["desc"], "id": r["id"],
                "class": r["class"], "bounds": r["bounds"],
                "clickable": r["clickable"], "scrollable": r["scrollable"],
                "enabled": r["enabled"], "flags": r["flags"],
            }, ensure_ascii=False))
        return

    if mode in ("find-text", "find-id", "pick-text", "pick-id"):
        by_id = mode.endswith("-id")
        matches = []
        for r in rows:
            if by_id:
                if exact:
                    hit = (needle == r["id"]) or r["id"].endswith("/" + needle)
                else:
                    hit = needle in r["id"]
            else:
                if exact:
                    hit = (r["text"] == needle) or (r["desc"] == needle)
                else:
                    hit = (needle in r["text"]) or (needle in r["desc"])
            if hit:
                matches.append(r)

        if mode.startswith("find"):
            if not matches:
                sys.exit(1)
            for r in matches:
                print(tsv_line(r))
            return

        # pick：优先 可点击且精确匹配 → 可点击 → 精确 → 包含；同级取面积最小
        cands = [r for r in matches if (r["x2"] - r["x"]) * (r["y2"] - r["y"]) > 0]
        if not cands:
            sys.exit(1)

        def rank(r):
            ex = (r["text"] == needle or r["desc"] == needle)
            if ex and r["clickable"]:
                return 0
            if r["clickable"]:
                return 1
            if ex:
                return 2
            return 3

        best = min(cands, key=lambda r: (rank(r), (r["x2"] - r["x"]) * (r["y2"] - r["y"])))
        cx = (best["x"] + best["x2"]) // 2
        cy = (best["y"] + best["y2"]) // 2
        # 第 1 行：点击坐标；第 2 行：节点摘要。分行输出避免 bash read 遇到空字段折叠。
        print(f"{cx} {cy}")
        parts = []
        if best["text"]:
            parts.append("text=" + esc(best["text"]))
        if best["desc"]:
            parts.append("desc=" + esc(best["desc"]))
        if best["id"]:
            parts.append("id=" + best["id"])
        parts.append(f'class={best["class"]}')
        parts.append(f'bounds={best["x"]},{best["y"]},{best["x2"]},{best["y2"]}')
        if best["flags"]:
            parts.append("flags=" + best["flags"])
        print(" | ".join(parts))
        return

    die(f"未知模式: {mode}", 3)


if __name__ == "__main__":
    main()