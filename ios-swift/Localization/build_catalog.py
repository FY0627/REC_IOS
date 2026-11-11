# -*- coding: utf-8 -*-
"""从 translations.py 生成 Bookkeeping/Localizable.xcstrings（ADR 0022）。

    python3 Localization/build_catalog.py          生成
    python3 Localization/build_catalog.py --check  只检查：代码里还有哪些中文文字没有翻译

键是代码里的简体中文原文；zh-Hans 的值就是键本身（写出来是为了一定生成 zh-Hans.lproj，
App 里选了简体中文、手机是别的语言时也能查到）。银行名称的英文从 BankCatalog.swift 读。
"""

import io
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUTPUT = os.path.join(ROOT, "Bookkeeping", "Localizable.xcstrings")
BANKS = os.path.join(ROOT, "Packages", "BKCore", "Sources", "BKModel", "BankCatalog.swift")

# 不翻译的：开发与调试里的页面（平时藏着）、性能诊断
SKIP_FILES = {"CategoryCheckupView.swift", "SimulationView.swift", "MetricsOverlay.swift", "PerfFlags.swift"}
SKIP_DIRS = {"Diagnostics"}


def load():
    scope = {}
    with io.open(os.path.join(HERE, "translations.py"), encoding="utf-8") as f:
        exec(compile(f.read(), "translations.py", "exec"), scope)
    entries = []
    seen = {}
    for key, tw, en, hans in scope["S"]:
        if key in seen:
            if seen[key] != (tw, en if isinstance(en, str) else (en.one, en.other)):
                sys.exit("重复的键，翻译不一样：" + key)
            continue
        seen[key] = (tw, en if isinstance(en, str) else (en.one, en.other))
        entries.append((key, tw, en, hans or key))
    # 银行：台湾叫法在 BANK_TW，英文用 BankCatalog 的英文名称
    pattern = re.compile(r'bank\("[^"]+", "([^"]+)", "([^"]+)"')
    with io.open(BANKS, encoding="utf-8") as f:
        for name, english in pattern.findall(f.read()):
            if name in seen:
                continue
            tw = scope["BANK_TW"].get(name, name)
            if tw == name and english == name:
                continue
            seen[name] = (tw, english)
            entries.append((name, tw, english, name))
    return entries, scope["P"]


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def specifiers(text):
    return re.findall(r"%(?:\d+\$)?(?:@|lld|ld|d|lf|f)", text)


def build():
    entries, plural = load()
    strings = {}
    for key, tw, en, hans in entries:
        keyspec = sorted(re.sub(r"\d+\$", "", s) for s in specifiers(key))
        variants = [tw] + ([en.one, en.other] if isinstance(en, plural) else [en])
        for value in variants:
            # 一个数量的英文单数可以不写数字（「1 card」以外的说法）；其他的占位符必须和键一样，否则格式化会出错
            spec = sorted(re.sub(r"\d+\$", "", s) for s in specifiers(value))
            if spec != keyspec and not (isinstance(en, plural) and value == en.one and spec == []):
                sys.exit("占位符和键对不上：%s → %s" % (key, value))
        if isinstance(en, plural):
            english = {"variations": {"plural": {"one": unit(en.one), "other": unit(en.other)}}}
        else:
            english = unit(en)
        strings[key] = {"localizations": {"en": english, "zh-Hans": unit(hans), "zh-Hant": unit(tw)}}
    catalog = {"sourceLanguage": "zh-Hans", "strings": dict(sorted(strings.items())), "version": "1.0"}
    text = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "))
    with io.open(OUTPUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(text + "\n")
    print("%d 条 → %s" % (len(strings), os.path.relpath(OUTPUT, ROOT)))


# MARK: 检查

HAN = re.compile(r"[一-鿿]")


def literals(source):
    """Swift 源码里的字符串字面量：返回 (行号, 片段列表)，插值 `\\(...)` 记成 None。跳过注释"""
    i, line, n = 0, 1, len(source)
    out = []
    while i < n:
        c = source[i]
        if c == "\n":
            line += 1
            i += 1
        elif source.startswith("//", i):
            while i < n and source[i] != "\n":
                i += 1
        elif source.startswith("/*", i):
            end = source.find("*/", i + 2)
            line += source.count("\n", i, end)
            i = end + 2
        elif source.startswith('#"', i):
            end = source.find('"#', i + 2)
            i = end + 2
        elif source.startswith('"""', i):
            end = source.find('"""', i + 3)
            line += source.count("\n", i, end)
            i = end + 3
        elif c == '"':
            parts, buf, start = [], [], line
            i += 1
            while i < n and source[i] != '"':
                if source[i] == "\\" and i + 1 < n and source[i + 1] == "(":
                    parts.append("".join(buf))
                    buf = []
                    depth, i = 1, i + 2
                    while i < n and depth:
                        if source[i] == '"':
                            i += 1
                            while i < n and source[i] != '"':
                                i += 2 if source[i] == "\\" else 1
                        elif source[i] == "(":
                            depth += 1
                        elif source[i] == ")":
                            depth -= 1
                        i += 1
                    parts.append(None)
                elif source[i] == "\\":
                    buf.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(source[i + 1], source[i + 1]))
                    i += 2
                else:
                    buf.append(source[i])
                    i += 1
            parts.append("".join(buf))
            out.append((start, parts))
            i += 1
        else:
            i += 1
    return out


def check():
    entries, _ = load()
    keys = [k for k, _, _, _ in entries]
    plain = set(keys)
    patterns = [re.compile("^" + re.sub(r"%(?:@|lld)", lambda _: "%(?:@|lld|lf|d)", re.escape(k).replace("%@", "%@").replace(r"\%", "%")) + "$") for k in keys if "%" in k]
    missing = 0
    for folder in ["Bookkeeping", "NotificationContent", "CategoryActivity", "Shared"]:
        for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, folder)):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in sorted(filenames):
                if not name.endswith(".swift") or name in SKIP_FILES:
                    continue
                path = os.path.join(dirpath, name)
                with io.open(path, encoding="utf-8") as f:
                    source = f.read()
                for line, parts in literals(source):
                    text = "".join(p if p is not None else "%@" for p in parts)
                    if not HAN.search(text):
                        continue
                    if "logger" in source.splitlines()[line - 1].lower():
                        continue
                    if text in plain or any(p.match(text) for p in patterns):
                        continue
                    missing += 1
                    print("%s:%d: %s" % (os.path.relpath(path, ROOT), line, text))
    print("没有翻译的：%d" % missing)


if __name__ == "__main__":
    if "--check" in sys.argv:
        check()
    else:
        build()
