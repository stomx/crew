#!/usr/bin/env bash
# Release helper for crew plugin.
#
# 사용법:
#   scripts/release.sh <new_version>       — 실제 릴리스
#   scripts/release.sh --dry-run <ver>     — 미리보기
#
# 동작:
#   1. plugin.json 의 version 을 <ver> 로 bump
#   2. 이전 태그 이후 커밋 제목을 모아 CHANGELOG.md 상단(소개문 직후)에 새 섹션 삽입
#      [X.Y.Z] - YYYY-MM-DD
#      ### <type>
#      - <subject 본문부>
#   3. commit → tag v<ver> → push main + tag → gh release 생성 (notes = 그 섹션)
#
# 전제:
#   - working tree clean
#   - gh CLI 인증 완료 (GitHub Release 용)

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
TAG="v${NEW_VER}"

[[ "$CUR_VER" != "$NEW_VER" ]] || { echo "error: plugin.json 이 이미 $NEW_VER" >&2; exit 4; }
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
  || { echo "error: $TAG 태그가 이미 존재" >&2; exit 5; }

if [[ $DRY_RUN -eq 0 ]]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "error: working tree dirty — 먼저 commit 하거나 stash 하세요" >&2
    git status --short
    exit 6
  fi
fi

TODAY=$(date +%Y-%m-%d)
PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
RANGE="${PREV_TAG:+$PREV_TAG..}HEAD"

# Conventional Commits 를 Keep-a-Changelog 섹션으로 매핑
classify() {
  case "$1" in
    feat)              echo "Added" ;;
    fix)               echo "Fixed" ;;
    perf|refactor)     echo "Changed" ;;
    docs|chore|test|*) echo "Other" ;;
  esac
}

# 현재 릴리스 커밋("chore: 릴리스 X.Y.Z")은 제외
declare -A buckets
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  [[ "$line" =~ ^chore:\ 릴리스\  ]] && continue
  # "type: subject" 분해
  if [[ "$line" =~ ^([a-zA-Z]+):\ (.+)$ ]]; then
    type="${BASH_REMATCH[1]}"
    subj="${BASH_REMATCH[2]}"
  else
    type="other"
    subj="$line"
  fi
  section=$(classify "$type")
  buckets[$section]+="- $subj"$'\n'
done < <(git log --format='%s' $RANGE 2>/dev/null || true)

# 새 섹션 텍스트 생성
new_section=$'\n## ['"$NEW_VER"$'] - '"$TODAY"$'\n'
for sec in Added Changed Fixed Other; do
  if [[ -n "${buckets[$sec]:-}" ]]; then
    new_section+=$'\n### '"$sec"$'\n'"${buckets[$sec]}"
  fi
done
# compare 각주
compare_line="[$NEW_VER]: https://github.com/stomx/crew/compare/${PREV_TAG:-v0.0.0}...${TAG}"

# CHANGELOG 에 새 섹션 삽입 — 첫 "## [" 바로 앞에.
# new_section 이 개행 포함 문자열이라 awk -v 로 넘길 수 없어 파일로 전달.
insert_file=$(mktemp)
printf '%s\n' "$new_section" > "$insert_file"
tmp=$(mktemp)
awk -v ins_file="$insert_file" '
  function load_insert(    line, buf) {
    buf=""
    while ((getline line < ins_file) > 0) buf = buf line "\n"
    close(ins_file)
    return buf
  }
  BEGIN { done=0; ins=load_insert() }
  /^## \[/ && !done {
    printf "%s", ins
    done=1
  }
  { print }
' "$CHANGELOG" > "$tmp"
rm -f "$insert_file"

# compare 각주를 파일 끝에 추가 (중복 방지)
if ! grep -qF "[$NEW_VER]:" "$tmp"; then
  printf '%s\n' "$compare_line" >> "$tmp"
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "=== DRY RUN ==="
  echo "current version: $CUR_VER"
  echo "new version:     $NEW_VER"
  echo "prev tag:        ${PREV_TAG:-(none)}"
  echo "commit range:    $RANGE"
  echo "--- CHANGELOG.md diff preview ---"
  diff -u "$CHANGELOG" "$tmp" || true
  echo "--- plugin.json diff preview ---"
  jq --arg v "$NEW_VER" '.version = $v' "$PLUGIN_JSON" | diff -u "$PLUGIN_JSON" - || true
  rm -f "$tmp"
  exit 0
fi

mv "$tmp" "$CHANGELOG"

jq --arg v "$NEW_VER" '.version = $v' "$PLUGIN_JSON" > "${PLUGIN_JSON}.tmp"
mv "${PLUGIN_JSON}.tmp" "$PLUGIN_JSON"

git add "$PLUGIN_JSON" "$CHANGELOG"
git commit -m "chore: 릴리스 $NEW_VER"
git tag -a "$TAG" -m "Release $NEW_VER"
git push origin main
git push origin "$TAG"

if command -v gh >/dev/null 2>&1; then
  notes=$(awk -v ver="$NEW_VER" '
    $0 == "## [" ver "] - '"$TODAY"'" { on=1; next }
    on && /^## \[/ { exit }
    on && /^\[[^ ]+\]:/ { exit }
    on { print }
  ' "$CHANGELOG")
  printf '%s' "$notes" | gh release create "$TAG" --title "$TAG" --notes-file - --latest
  echo "✓ GitHub Release 생성: $TAG"
else
  echo "warning: gh CLI 없음 — 수동으로 https://github.com/stomx/crew/releases/new?tag=$TAG 방문" >&2
fi

echo "✓ $NEW_VER 릴리스 완료"
