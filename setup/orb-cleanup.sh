#!/usr/bin/env bash
# Removes old stopped orbs and snapshots from the orbs project. Running orbs are never touched.
# A removed orb's thread starts fresh on its next message, so uncommitted work in it is lost.
# Set ORB_CLEANUP_DRY_RUN=1 to only list what would go.
set -euo pipefail

PROJECT="${INCUS_PROJECT:-orbs}"
ORB_DAYS="${ORB_CLEANUP_ORB_DAYS:-30}"
SNAPSHOT_DAYS="${ORB_CLEANUP_SNAPSHOT_DAYS:-14}"
MATCH="${ORB_CLEANUP_MATCH:-^amp-}"
now="$(date +%s)"
removed=0

while IFS=$'\t' read -r name status created used; do
  [[ "$name" =~ $MATCH ]] || continue
  [ "$status" = Stopped ] || continue
  if [[ "$name" == amp-snap-* ]]; then
    since="$created"; days="$SNAPSHOT_DAYS"
  else
    since="$used"; days="$ORB_DAYS"
    # An instance that has never started reports year 1 or 1970, so go by when it was created.
    if [[ "$since" == 0001-* || "$since" == 1970-* ]]; then since="$created"; fi
  fi
  age=$(( (now - $(date -d "$since" +%s)) / 86400 ))
  [ "$age" -ge "$days" ] || continue
  if [ -n "${ORB_CLEANUP_DRY_RUN:-}" ]; then
    echo "would remove $name (unused for $age days)"
  else
    incus --project "$PROJECT" delete "$name" </dev/null
    echo "removed $name (unused for $age days)"
  fi
  removed=$((removed + 1))
done < <(incus --project "$PROJECT" list --format json </dev/null | jq -r '.[] | [.name, .status, .created_at, .last_used_at] | @tsv')

echo "cleanup done: $removed item(s)"
