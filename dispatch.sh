#!/usr/bin/env bash
# Experimental: Amp orb provider dispatch program backed by Incus containers.
# Amp runs this once per job with ORB_OPERATION, ORB_ID and friends in the environment.
set -euo pipefail

PROJECT="${INCUS_PROJECT:-orbs}"
BASE_IMAGE="${INCUS_BASE_IMAGE:-amp-orb-base}"
MAX_RUNNING="${MAX_RUNNING_ORBS:-2}"
TYPES_DIR="${ORB_TYPES_DIR:-/etc/amp-orbs/types}"

inc() { incus --project "$PROJECT" "$@"; }

# Only ever touch instances named amp-*, in the orbs project.
case "${ORB_ID:-}" in
  amp-*) ;;
  *) echo "refusing ORB_ID '${ORB_ID:-}': must start with amp-" >&2; exit 1 ;;
esac

exists() { inc info "$1" >/dev/null 2>&1; }

# An Orb type is a file in $TYPES_DIR named <type>.conf, setting IMAGE and optionally MEMORY
# and READY_CMD. Any other ORB_TYPE, including none, uses the base image.
pick_type() {
  local type="${ORB_TYPE:-}"
  # The type ends up in instance names, which allow 63 characters, so keep it short.
  if [[ "$type" =~ ^[a-z0-9][a-z0-9-]{0,20}$ ]] && [ -f "$TYPES_DIR/$type.conf" ]; then
    echo "$type"
  else
    echo default
  fi
}

load_type() {
  IMAGE="$BASE_IMAGE" MEMORY="" READY_CMD=""
  [ "$1" = default ] || [ ! -f "$TYPES_DIR/$1.conf" ] || . "$TYPES_DIR/$1.conf"
}

# Snapshot IDs come from Amp and become instance names, which allow only letters, digits and hyphens.
# Each type keeps its own snapshots, so a thread never starts from a copy of another type.
snap_name() {
  if [ "$1" = default ]; then
    echo "amp-snap-$(printf '%s' "$2" | tr -c 'a-zA-Z0-9-' '-')"
  else
    # Amp's IDs are long, so typed names use a hash to stay under 63 characters.
    echo "amp-snap-$1-$(printf '%s' "$2" | sha256sum | cut -c1-32)"
  fi
}

# Amp only sends ORB_TYPE on spawn, so it's saved on the instance for later jobs to read.
saved_type() {
  local type
  type="$(inc config get "$ORB_ID" user.orb_type 2>/dev/null || true)"
  echo "${type:-default}"
}

create_orb() {
  local type="$1" snap=""
  load_type "$type"
  [ -z "${ORB_SNAPSHOT_ID:-}" ] || snap="$(snap_name "$type" "$ORB_SNAPSHOT_ID")"
  if [ -n "$snap" ] && exists "$snap"; then
    inc copy "$snap" "$ORB_ID"
  else
    # incus init waits for YAML on stdin when it isn't a terminal.
    inc init "$IMAGE" "$ORB_ID" </dev/null
  fi
  inc config set "$ORB_ID" user.orb_type="$type" </dev/null
  [ -z "$MEMORY" ] || inc config set "$ORB_ID" limits.memory="$MEMORY" </dev/null
}

# READY_CMD runs inside the Orb until it succeeds, e.g. a database ping, before Amp starts work.
wait_for_type() {
  load_type "$(saved_type)"
  [ -n "$READY_CMD" ] || return 0
  for _ in $(seq 1 60); do
    inc exec "$ORB_ID" -- sh -c "$READY_CMD" >/dev/null 2>&1 </dev/null && return 0
    sleep 1
  done
  echo "$ORB_ID not ready: '$READY_CMD' kept failing" >&2
  return 1
}

wait_ready() {
  for _ in $(seq 1 30); do
    # Bootstrap exits straight away if DNS isn't up yet, which happens right after a restart.
    inc exec "$ORB_ID" -- getent hosts ampcode.com >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "instance $ORB_ID did not become ready" >&2
  return 1
}

spawn() {
  if [ "$(inc list "^${ORB_ID}\$" -f csv -c s)" != "RUNNING" ]; then
    # Project memory limits also count stopped instances, so cap running orbs here instead.
    running="$(inc list -f csv -c s | grep -c '^RUNNING$' || true)"
    if [ "$running" -ge "$MAX_RUNNING" ]; then
      echo "already running $running orbs (limit $MAX_RUNNING); pause one first" >&2
      exit 1
    fi
  fi

  if ! exists "$ORB_ID"; then
    create_orb "$(pick_type)"
  fi

  [ "$(inc list "^${ORB_ID}\$" -f csv -c s)" = "RUNNING" ] || inc start "$ORB_ID"
  wait_ready
  wait_for_type

  # The token goes over stdin so it never shows up in a process list.
  inc exec "$ORB_ID" -- bash -c 'mkdir -p -m 755 /etc/amp-orb; umask 077; cat > /etc/amp-orb/env; chown user:user /etc/amp-orb/env' <<EOF
ORB_TOKEN=${ORB_TOKEN:-}
AMP_URL=${AMP_URL:-}
EOF

  inc exec "$ORB_ID" -- bash -c '
    pkill -u user -f "amp orb bootstrap" 2>/dev/null || true
    sudo -iu user bash -c "set -a; . /etc/amp-orb/env; set +a; [ -n \"\$AMP_URL\" ] || unset AMP_URL; nohup setsid amp orb bootstrap >/home/user/.orb-bootstrap.log 2>&1 < /dev/null &"
  '
}

pause() {
  if exists "$ORB_ID"; then
    # Drop the token before stopping, so it isn't kept on disk.
    inc exec "$ORB_ID" -- rm -f /etc/amp-orb/env >/dev/null 2>&1 || true
    # A clean shutdown first, so a database inside can flush to disk.
    inc stop "$ORB_ID" --timeout 30 >/dev/null 2>&1 || inc stop "$ORB_ID" --force >/dev/null 2>&1 || true
    if [ -n "${ORB_SNAPSHOT_ID:-}" ]; then
      local snap tmp
      snap="$(snap_name "$(saved_type)" "$ORB_SNAPSHOT_ID")"
      tmp="${snap}-tmp"
      inc delete "$tmp" --force >/dev/null 2>&1 || true
      inc copy "$ORB_ID" "$tmp"
      inc delete "$snap" --force >/dev/null 2>&1 || true
      inc move "$tmp" "$snap"
    fi
  fi
}

delete() {
  if exists "$ORB_ID"; then
    inc delete "$ORB_ID" --force
  fi
}

case "${ORB_OPERATION:-}" in
  spawn) spawn ;;
  pause) pause ;;
  delete) delete ;;
  *) echo "unknown ORB_OPERATION '${ORB_OPERATION:-}'" >&2; exit 1 ;;
esac
