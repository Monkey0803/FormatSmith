#!/bin/bash
# 打一个发布版本。
#
# 用法:
#   ./scripts/release.sh 1.0.0                # 更新 VERSION、提交、打 tag、推送
#   ./scripts/release.sh 1.0.0 --dry-run      # 只在本地产出 DMG 检查，不提交也不推送
#
# 推送 tag 之后，.github/workflows/release.yml 会在 macOS runner 上
# 构建通用二进制、打包 DMG，并创建 GitHub Release。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="FormatSmith"
DRY_RUN=false
VERSION=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Unknown option: $arg" >&2; exit 1 ;;
        *) VERSION="$arg" ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo "usage: ./scripts/release.sh <version> [--dry-run]" >&2
    exit 2
fi

if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "✗ version must look like 1.2.3, got: $VERSION" >&2
    exit 2
fi

cd "$ROOT"

if [ "$DRY_RUN" = true ]; then
    echo "▶ Dry run: building $APP_NAME $VERSION locally (VERSION file untouched)"
    ./scripts/build-app.sh --universal --dmg
    echo "✓ Dry run finished. Artefacts are in dist/."
    exit 0
fi

# 真正的发布会动 git，所以先把能挡的都挡掉。
if [ -n "$(git status --porcelain)" ]; then
    echo "✗ working tree is dirty; commit or stash first" >&2
    git status --short
    exit 1
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo "✗ releases are cut from main, currently on $CURRENT_BRANCH" >&2
    exit 1
fi

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "✗ tag v$VERSION already exists" >&2
    exit 1
fi

echo "▶ Running the test suite before tagging…"
swift test >/dev/null

echo "▶ Writing VERSION and CHANGELOG…"
printf '%s\n' "$VERSION" > VERSION
TODAY="$(date +%Y-%m-%d)"
python3 - "$VERSION" "$TODAY" <<'PY'
import re, sys
version, today = sys.argv[1], sys.argv[2]
path = "CHANGELOG.md"
text = open(path, encoding="utf-8").read()
if f"## [{version}]" not in text:
    text = text.replace(
        "## [Unreleased]",
        f"## [Unreleased]\n\n## [{version}] - {today}",
        1,
    )
    # 让 Unreleased 的链接指向新版本
    text = re.sub(
        r"^\[Unreleased\]: .*$",
        f"[Unreleased]: https://github.com/Monkey0803/FormatSmith/compare/v{version}...HEAD\n"
        f"[{version}]: https://github.com/Monkey0803/FormatSmith/releases/tag/v{version}",
        text,
        count=1,
        flags=re.M,
    )
open(path, "w", encoding="utf-8").write(text)
PY

echo "▶ Committing and tagging…"
git add VERSION CHANGELOG.md
if git diff --cached --quiet; then
    # VERSION 与 CHANGELOG 已经是这个版本了（例如手工改过），直接打 tag。
    echo "  VERSION and CHANGELOG already at $VERSION; nothing to commit"
else
    git commit -q -m "chore(release): 发布 $VERSION

- 将 VERSION 提升到 $VERSION
- 在 CHANGELOG 中固化 $VERSION 的发布条目
"
fi
git tag -a "v$VERSION" -m "$APP_NAME $VERSION"

echo "▶ Pushing main and the tag…"
git push origin main
git push origin "v$VERSION"

echo "✓ Tagged v$VERSION. The release workflow will publish the DMG:"
echo "  https://github.com/Monkey0803/FormatSmith/actions/workflows/release.yml"
