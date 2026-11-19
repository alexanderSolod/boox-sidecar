#!/bin/bash
# Polls GitHub for newly opened issues and pull requests on this repo.
# New items print to the terminal and fire a macOS notification.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${BOOX_REPO:-$(gh repo view "$ROOT" --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo 'alexanderSolod/boox-sidecar')}"
INTERVAL="${BOOX_WATCH_INTERVAL:-120}"
STATE="${BOOX_WATCH_STATE:-$HOME/.cache/boox-sidecar-watch.state}"
mkdir -p "$(dirname "$STATE")"; touch "$STATE"

check() {
  local kind="$1" endpoint="$2"
  gh api "repos/$REPO/$endpoint?state=open&per_page=50" \
      --jq '.[] | "\(.number)\t\(.title)\t\(.user.login)"' 2>/dev/null |
  while IFS=$'\t' read -r number title author; do
    [[ -n "$number" ]] || continue
    key="$kind#$number"
    grep -qxF "$key" "$STATE" && continue
    echo "$key" >> "$STATE"
    [[ "$PRIMED" == true ]] && continue
    echo "[$(date '+%H:%M')] New $kind #$number by $author: $title"
    osascript -e "display notification \"${title//\"/\\\"}\" with title \"boox-sidecar: new $kind #$number\"" 2>/dev/null || true
  done
}

[[ -s "$STATE" ]] && PRIMED=true || PRIMED=false
echo "Watching $REPO every ${INTERVAL}s (state: $STATE)"
while true; do
  check issue issues
  check "pull request" pulls
  PRIMED=true
  sleep "$INTERVAL"
done
