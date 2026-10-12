#!/usr/bin/env bash
# 两份 README 的结构必须对得上。
#
# 英文 README 是源、中文是译本。功能一多，最常见的文档问题不是「写错了」，
# 而是「一边更新了、另一边没跟上」—— 中文读者看到的还是上一个版本的功能，
# 而且没有任何迹象提示他们。
#
# 这里只查「结构」，不查措辞：标题与代码块的数量必须一致。
# 措辞没法自动查，但结构与命令示例能查，而它们恰好是最容易漂移的部分。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EN="$ROOT/README.md"
ZH="$ROOT/README.zh-Hans.md"

problems=0
fail() { printf '  x %s\n' "$1"; problems=$((problems + 1)); }
pass() { printf '  ok %s\n' "$1"; }

[ -f "$EN" ] || { echo "missing README.md"; exit 1; }
[ -f "$ZH" ] || { echo "missing README.zh-Hans.md"; exit 1; }

echo "README structure consistency"

en_headings=$(grep -c '^#' "$EN")
zh_headings=$(grep -c '^#' "$ZH")
if [ "$en_headings" = "$zh_headings" ]; then
    pass "heading count matches: $en_headings"
else
    fail "heading count differs: en=$en_headings zh=$zh_headings"
fi

en_fences=$(grep -c '^```' "$EN")
zh_fences=$(grep -c '^```' "$ZH")
if [ "$en_fences" = "$zh_fences" ]; then
    pass "code fence count matches: $en_fences"
else
    fail "code fence count differs: en=$en_fences zh=$zh_fences"
fi

# 命令行示例必须逐字保留：从中文 README 复制出来的命令要能直接跑
missing=0
while IFS= read -r flag; do
    [ -z "$flag" ] && continue
    if ! grep -qF -- "$flag" "$ZH"; then
        fail "Chinese README is missing a flag: $flag"
        missing=$((missing + 1))
    fi
done < <(grep -oE '\-\-[a-z][a-z-]+' "$EN" | sort -u)

[ "$missing" = 0 ] && pass "all CLI flags kept verbatim"

# 站内锚点必须真的存在。
# 翻译标题会顺带弄坏 `](#some-heading)` 这类链接：标题变成中文，锚点就不再是英文了。
# 死链点不动，而且没有任何报错 —— 只能靠查。
check_anchors() {
    local file="$1"
    # 用 python 做真正的比对：锚点规则（大小写、空格转连字符、去标点）用 shell 拼不准确
    python3 - "$file" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
links = set(re.findall(r'\]\(#([^)]+)\)', text))
headings = re.findall(r'^#{1,6}\s+(.+?)\s*$', text, re.M)
def slug(h):
    s = h.strip().lower()
    s = re.sub(r'[^\w\s\u4e00-\u9fff-]', '', s)
    return re.sub(r'\s+', '-', s)
slugs = {slug(h) for h in headings}
dead = sorted(links - slugs)
if dead:
    print("DEAD " + ", ".join("#" + d for d in dead))
PY
}

for doc in "$EN" "$ZH"; do
    result="$(check_anchors "$doc")"
    if [ -n "$result" ]; then
        fail "$(basename "$doc") has a dead in-page link: ${result#DEAD }"
    else
        pass "$(basename "$doc") in-page links resolve"
    fi
done

grep -q 'README.zh-Hans.md' "$EN" || fail "English README does not link to the Chinese one"
grep -q 'README.md' "$ZH" || fail "Chinese README does not link back to the English one"

if [ "$problems" -eq 0 ]; then
    echo "docs check passed"
    exit 0
fi
echo "docs check failed: $problems problem(s)"
exit 1
