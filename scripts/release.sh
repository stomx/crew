#!/usr/bin/env bash
# Release helper for crew plugin.
#
# 사용법:
#   scripts/release.sh <new_version>     — plugin.json bump + CHANGELOG unreleased 승격 + commit + tag + push + GitHub Release
#   scripts/release.sh --dry-run <ver>   — 실제 git/gh 호출 없이 변경 미리보기
#
# 전제:
#   1. CHANGELOG.md 의 [Unreleased] 섹션에 이 버전의 변경점이 이미 작성돼 있을 것.
#   2. working tree clean (CHANGELOG.md/plugin.json 외 미커밋 변경 없음).
#   3. gh CLI 가 인증돼 있을 것 (GitHub Release 용).
#
# 버전 규칙: semver. 기존 최신 태그보다 커야 함.

set -euo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi

NEW_VER="${1:-}"
if [[ -z "$NEW_VER" ]]; then
  echo "usage: $0 [--dry-run] <new_version>" >&2
  exit 1
fi

# semver 체크 (prerelease/build metadata 허용)
if ! [[ "$NEW_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+].+)?$ ]]; then
  echo "error: $NEW_VER 는 semver 형식이 아님" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
CHANGELOG="$REPO_ROOT/CHANGELOG.md"

[[ -f "$PLUGIN_JSON" ]] || { echo "error: $PLUGIN_JSON 없음" >&2; exit 3; }
[[ -f "$CHANGELOG"   ]] || { echo "error: $CHANGELOG 없음"   >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "error: jq 필요"   >&2; exit 3; }

CUR_VER=$(jq -r .version "$PLUGIN_JSON")

if [[ "$CUR_VER" == "$NEW_VER" ]]; then
  echo "error: plugin.json 이 이미 $NEW_VER — 버전을 올려야 함" >&2
  exit 4
fi

TAG="v${NEW_VER}"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "error: $TAG 태그가 이미 존재" >&2
  exit 5
fi

if [[ $DRY_RUN -eq 0 ]]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "error: working tree dirty — 먼저 commit 하거나 stash 하세요" >&2
    git status --short
    exit 6
  fi
fi

TODAY=$(date +%Y-%m-%d)

# CHANGELOG 의 Unreleased 섹션을 버전 섹션으로 승격
# 정확히 "## [Unreleased]" 라인을 "## [X.Y.Z] - YYYY-MM-DD" 로 바꾸고
# 그 직전에 빈 [Unreleased] 를 새로 삽입
tmp_changelog=$(mktemp)
awk -v ver="$NEW_VER" -v today="$TODAY" '
  BEGIN { replaced=0 }
  /^## \[Unreleased\]$/ && !replaced {
    print "## [Unreleased]"
    print ""
    print "## [" ver "] - " today
    replaced=1
    next
  }
  { print }
' "$CHANGELOG" > "$tmp_changelog"

if ! diff -q "$CHANGELOG" "$tmp_changelog" >/dev/null 2>&1; then
  :
else
  echo "warning: CHANGELOG.md 에 [Unreleased] 섹션이 없어 승격 생략" >&2
fi

# 링크 각주에 새 버전 compare 추가 — 파일 끝에 형식 [X.Y.Z]: .../compare/vPREV...vX.Y.Z
# 기존 [Unreleased] compare 링크의 ...HEAD 왼쪽 태그도 새 버전으로 교체
tmp_changelog2=$(mktemp)
awk -v ver="$NEW_VER" -v prev="$CUR_VER" -v today="$TODAY" '
  /^\[Unreleased\]:/ {
    # [Unreleased]: https://github.com/stomx/crew/compare/vX...HEAD
    gsub(/v[0-9][^.]*\.[0-9]+\.[0-9]+(\.\.\.HEAD)/, "v" ver "...HEAD")
    print
    # 바로 뒤에 새 버전 링크 추가
    print "[" ver "]: https://github.com/stomx/crew/compare/v" prev "...v" ver
    next
  }
  { print }
' "$tmp_changelog" > "$tmp_changelog2"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "=== DRY RUN ==="
  echo "current version: $CUR_VER"
  echo "new version:     $NEW_VER"
  echo "tag:             $TAG"
  echo "today:           $TODAY"
  echo "--- CHANGELOG.md diff preview ---"
  diff -u "$CHANGELOG" "$tmp_changelog2" || true
  echo "--- plugin.json diff preview ---"
  jq --arg v "$NEW_VER" '.version = $v' "$PLUGIN_JSON" | diff -u "$PLUGIN_JSON" - || true
  rm -f "$tmp_changelog" "$tmp_changelog2"
  exit 0
fi

# 실제 적용
mv "$tmp_changelog2" "$CHANGELOG"
rm -f "$tmp_changelog"

jq --arg v "$NEW_VER" '.version = $v' "$PLUGIN_JSON" > "${PLUGIN_JSON}.tmp"
mv "${PLUGIN_JSON}.tmp" "$PLUGIN_JSON"

git add "$PLUGIN_JSON" "$CHANGELOG"
git commit -m "chore: 릴리스 $NEW_VER"

git tag -a "$TAG" -m "Release $NEW_VER"
git push origin main
git push origin "$TAG"

# GitHub Release (gh 있으면 자동, 없으면 수동 안내)
if command -v gh >/dev/null 2>&1; then
  # CHANGELOG 에서 이 버전 섹션만 추출 (다음 ## 또는 각주 전까지)
  notes=$(awk -v ver="$NEW_VER" '
    $0 == "## [" ver "] - '"$TODAY"'" { on=1; next }
    on && /^## \[/ { exit }
    on && /^\[[^ ]+\]:/ { exit }
    on { print }
  ' "$CHANGELOG")
  printf '%s' "$notes" | gh release create "$TAG" --title "$TAG" --notes-file -
  echo "✓ GitHub Release 생성: $TAG"
else
  echo "warning: gh CLI 없음 — 수동으로 https://github.com/stomx/crew/releases/new?tag=$TAG 방문" >&2
fi

echo "✓ $NEW_VER 릴리스 완료"
