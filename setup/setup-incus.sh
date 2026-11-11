#!/usr/bin/env bash
# Installs Incus, the orbs project, the orb base image and the provider service.
# Run as root on Debian 13 from the repo root. Safe to run again; existing pieces are kept.
set -euo pipefail

PROVIDER_USER="${PROVIDER_USER:-debian}"
ORB_MEMORY="${ORB_MEMORY:-2GiB}"
POOL_SIZE="${POOL_SIZE:-25GiB}"
BASE_IMAGE="amp-orb-base"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

# incus create commands wait for YAML on stdin when it isn't a terminal.
exec </dev/null

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq incus btrfs-progs jq curl >/dev/null
usermod -aG incus-admin "$PROVIDER_USER"

if ! incus storage show default >/dev/null 2>&1; then
  incus admin init --preseed <<YAML
config: {}
networks:
- name: incusbr0
  type: bridge
  config:
    ipv4.address: auto
    ipv6.address: none
storage_pools:
- name: default
  driver: btrfs
  config:
    size: $POOL_SIZE
profiles:
- name: default
  devices:
    eth0: {name: eth0, network: incusbr0, type: nic}
    root: {path: /, pool: default, type: disk}
YAML
fi

# Orbs get their own project, so the script can't see instances in the default project.
if ! incus project show orbs >/dev/null 2>&1; then
  incus project create orbs -c features.images=false -c features.profiles=true
  incus profile device add default root disk path=/ pool=default --project orbs
  incus profile device add default eth0 nic network=incusbr0 name=eth0 --project orbs
fi
# This is per orb. Don't set limits.memory on the project: it also counts stopped orbs.
incus profile set default limits.memory="$ORB_MEMORY" --project orbs

if ! incus image info "$BASE_IMAGE" >/dev/null 2>&1; then
  incus launch images:debian/13 amp-base-build
  until incus exec amp-base-build -- getent hosts deb.debian.org >/dev/null 2>&1; do sleep 1; done
  incus exec amp-base-build -- bash -c '
    set -e
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo git curl ca-certificates nodejs tmux ripgrep openssh-client util-linux >/dev/null
    useradd -m -s /bin/bash user
    echo "user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/user
    chmod 440 /etc/sudoers.d/user
    sudo -iu user bash -c "curl -fsSL https://ampcode.com/install.sh | bash"
    ln -sf /home/user/.amp/bin/amp /usr/local/bin/amp
    chmod a+rx /home/user
    amp --version
  '
  incus stop amp-base-build
  incus publish amp-base-build --alias "$BASE_IMAGE"
  incus delete amp-base-build
fi

[ -x "/home/$PROVIDER_USER/.amp/bin/amp" ] || sudo -iu "$PROVIDER_USER" bash -c "curl -fsSL https://ampcode.com/install.sh | bash"
ln -sf "/home/$PROVIDER_USER/.amp/bin/amp" /usr/local/bin/amp

install -d /opt/amp-orbs
install -m 755 "$REPO_DIR/dispatch.sh" /opt/amp-orbs/dispatch.sh
install -m 755 "$REPO_DIR/setup/set-amp-token" /usr/local/bin/set-amp-token
sed "s/^User=.*/User=$PROVIDER_USER/" "$REPO_DIR/setup/amp-orb-provider.service" > /etc/systemd/system/amp-orb-provider.service
systemctl daemon-reload

echo "Done. Next: sudo set-amp-token"
