#!/usr/bin/env bash
# Usage:
#   slot.sh read  <slug> <pane_idx>         → prints slot file path
#   slot.sh share <slug> <from_idx> <to_idx> → injects "참고자료: <slot>" prompt
#                                              into to-pane so it can ingest from-pane output
#
# "sub pane 간 데이터 교환" 을 스킬 레벨에서 지원.
# 실제 전달은 prompt 를 통해 간접적 — pane 은 서로 직접 통신하지 않고,
# 메인 오케스트레이터(이 스크립트) 가 다리 역할.
#
# NOTE: share 는 대상 pane 에 "다음 참고자료를 검토하라" 프롬프트를 자동 주입한다.
# 메인이 이 명령을 호출하고 그 후 다시 wait_idle 로 응답을 기다리면 됨.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
source "$HERE/common.sh"

ACTION="${1:?action required: read|share}"

case "$ACTION" in
  read)
    SLUG="${2:?slug required}"
    IDX="${3:?pane idx required}"
    SLOT="$(crew_slot_path "$SLUG" "$IDX")"
    [[ -f "$SLOT" ]] || { echo "error: slot not found: $SLOT" >&2; exit 1; }
    echo "$SLOT"
    ;;
  share)
    SLUG="${2:?slug required}"
    FROM="${3:?from pane idx required}"
    TO="${4:?to pane idx required}"

    # FROM 은 숫자 (현재 run 의 pane) 또는 "prev:N" / "prev-K:N" (이전 run 의 pane).
    case "$FROM" in
      prev:*|prev-*:* )
        FROM_SLOT="$(crew_resolve_share_ref "$FROM")"
        FROM_LABEL="$FROM"
        ;;
      * )
        FROM_SLOT="$(crew_slot_path "$SLUG" "$FROM")"
        FROM_LABEL="pane-$FROM"
        ;;
    esac
    [[ -n "$FROM_SLOT" && -f "$FROM_SLOT" ]] \
      || { echo "error: from-slot missing: $FROM_SLOT (ref: $FROM)" >&2; exit 2; }

    # Craft a prompt that pastes the from-slot content for the to-pane to ingest.
    TMP="$(mktemp -t crew-share.XXXXXX)"
    {
      echo "다른 pane($FROM_LABEL) 에서 아래 결과를 받았습니다. 이를 참고해 다음 단계를 수행해 주세요."
      echo
      echo "----- BEGIN $FROM_LABEL OUTPUT -----"
      cat "$FROM_SLOT"
      echo "----- END $FROM_LABEL OUTPUT -----"
    } > "$TMP"

    "$HERE/dispatch.sh" "$SLUG" "$TO" "$TMP"
    rm -f "$TMP"
    ;;
  *)
    echo "usage: slot.sh read|share <args>" >&2
    exit 1
    ;;
esac
