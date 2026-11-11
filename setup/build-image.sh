#!/usr/bin/env bash
# Builds a custom Orb image: starts from the base image, runs your provision script inside it as
# root, adds an optional AGENTS.md for the Orb's user, and publishes the result.
# Run as root on the Incus host, from the repo root:
#   sudo ./setup/build-image.sh IMAGE PROVISION_SCRIPT [AGENTS_MD] [< input]
# Stdin goes to the provision script, e.g. a database dump. Variables named ORB_BUILD_* are
# passed in, so `sudo ORB_BUILD_SECRET=... ./setup/build-image.sh ...` reaches the script.
set -euo pipefail

IMAGE="${1:?usage: build-image.sh IMAGE PROVISION_SCRIPT [AGENTS_MD]}"
PROVISION="${2:?usage: build-image.sh IMAGE PROVISION_SCRIPT [AGENTS_MD]}"
AGENTS_MD="${3:-}"
BASE_IMAGE="${BASE_IMAGE:-amp-orb-base}"
BUILD="${BUILD:-${IMAGE}-build}"

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$PROVISION" ] || { echo "no provision script at $PROVISION" >&2; exit 1; }
[ -z "$AGENTS_MD" ] || [ -f "$AGENTS_MD" ] || { echo "no AGENTS.md at $AGENTS_MD" >&2; exit 1; }

# Keep a terminal's stdin away from incus, which would otherwise wait for YAML or a TTY.
[ ! -t 0 ] || exec </dev/null

envs=()
for name in $(compgen -e | grep '^ORB_BUILD_' || true); do
  envs+=(--env "$name=${!name}")
done

in_build() { incus exec "$BUILD" -- "$@"; }

incus delete "$BUILD" --force >/dev/null 2>&1 </dev/null || true
incus launch "$BASE_IMAGE" "$BUILD" </dev/null
until in_build getent hosts deb.debian.org >/dev/null 2>&1 </dev/null; do sleep 1; done

incus file push "$PROVISION" "$BUILD/root/provision.sh" </dev/null
echo "Running $PROVISION"
incus exec "$BUILD" "${envs[@]}" -- bash /root/provision.sh
in_build rm -f /root/provision.sh </dev/null

if [ -n "$AGENTS_MD" ]; then
  in_build mkdir -p /home/user/.config/amp </dev/null
  incus file push "$AGENTS_MD" "$BUILD/home/user/.config/amp/AGENTS.md" </dev/null
  in_build chown -R user:user /home/user/.config </dev/null
fi

incus stop "$BUILD" --timeout 60 </dev/null || incus stop "$BUILD" --force </dev/null
incus image delete "$IMAGE" >/dev/null 2>&1 </dev/null || true
incus publish "$BUILD" --alias "$IMAGE" --compression zstd </dev/null
incus delete "$BUILD" </dev/null

echo "Done. New Orbs of types using IMAGE=$IMAGE start from it. Existing Orbs keep their copy."
