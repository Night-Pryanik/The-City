# Временный скрипт валидации data/*.json: вырезает комментарии так же, как
# data_loader.gd (_strip_json_comments — с учётом строк), затем парсит JSON.
import json
import os
import sys


def strip_comments(text: str) -> str:
    result = []
    in_string = False
    in_single = False
    in_multi = False
    i = 0
    while i < len(text):
        c = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        prev = text[i - 1] if i > 0 else ""
        if not in_string and not in_single and not in_multi:
            if c == '"':
                in_string = True
                result.append(c)
                i += 1
                continue
            if c == "/" and nxt == "/":
                in_single = True
                i += 2
                continue
            if c == "/" and nxt == "*":
                in_multi = True
                i += 2
                continue
        if in_string:
            if c == '"' and prev != "\\":
                in_string = False
            result.append(c)
            i += 1
            continue
        if in_single:
            if c == "\n":
                in_single = False
                result.append(c)
            i += 1
            continue
        if in_multi:
            if c == "*" and nxt == "/":
                in_multi = False
                i += 2
                continue
            i += 1
            continue
        result.append(c)
        i += 1
    return "".join(result)


def main(root: str) -> int:
    failed = 0
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if not name.endswith(".json"):
                continue
            path = os.path.join(dirpath, name)
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            try:
                json.loads(strip_comments(text))
                print("OK  ", os.path.relpath(path, root))
            except json.JSONDecodeError as exc:
                failed += 1
                print("FAIL", os.path.relpath(path, root), "-", exc)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "data"))

import json, io

def strip_comments(s):
    res = []
    i = 0
    n = len(s)
    in_str = in_sl = in_ml = False
    while i < n:
        c = s[i]
        nx = s[i + 1] if i + 1 < n else ""
        pr = s[i - 1] if i > 0 else ""
        if not in_str and not in_sl and not in_ml:
            if c == '"':
                in_str = True
                res.append(c)
                i += 1
                continue
            if c == "/" and nx == "/":
                in_sl = True
                i += 2
                continue
            if c == "/" and nx == "*":
                in_ml = True
                i += 2
                continue
        if in_str:
            if c == '"' and pr != "\\":
                in_str = False
            res.append(c)
            i += 1
            continue
        if in_sl:
            if c == "\n":
                in_sl = False
                res.append(c)
            i += 1
            continue
        if in_ml:
            if c == "*" and nx == "/":
                in_ml = False
                i += 2
                continue
            i += 1
            continue
        res.append(c)
        i += 1
    return "".join(res)

files = [
    "data/consumption.json",
    "data/professions.json",
    "data/products/products.json",
    "data/product_groups.json",
    "data/crafts/crafts.json",
    "data/improvements.json",
    "data/game_balance.json",
]
for f in files:
    txt = strip_comments(io.open(f, encoding="utf-8").read())
    json.loads(txt)
    print("OK", f)
print("ALL JSON OK")