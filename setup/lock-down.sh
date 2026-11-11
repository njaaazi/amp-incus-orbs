#!/usr/bin/env bash
# Stops orbs reaching private networks, and limits the provider to the orbs project.
# Run as root after setup-incus.sh, from the repo root. Safe to run again.
set -euo pipefail

PROVIDER_USER="${PROVIDER_USER:-amp-orb}"
NETWORK="${ORB_NETWORK:-incusbr0}"
exec </dev/null

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

# Incus network ACLs need the nftables firewall driver.
if ! command -v nft >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables >/dev/null
  systemctl restart incus
fi

incus network acl show orb-egress >/dev/null 2>&1 || incus network acl create orb-egress
for range in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16; do
  incus network acl rule add orb-egress egress action=reject destination="$range" state=enabled 2>/dev/null || true
done
incus network set "$NETWORK" security.acls=orb-egress \
  security.acls.default.egress.action=allow security.acls.default.ingress.action=allow

incus project set orbs restricted=true

id "$PROVIDER_USER" >/dev/null 2>&1 || useradd --system --create-home --shell /bin/bash "$PROVIDER_USER"
home="$(getent passwd "$PROVIDER_USER" | cut -d: -f6)"
[ -x "$home/.amp/bin/amp" ] || sudo -iu "$PROVIDER_USER" bash -c "curl -fsSL https://ampcode.com/install.sh | bash" >/dev/null

# A restricted client certificate can only see the orbs project.
incus config set core.https_address 127.0.0.1:8443
if ! sudo -iu "$PROVIDER_USER" incus remote list -f csv 2>/dev/null | grep -q '^orbs-host'; then
  incus config trust remove "$PROVIDER_USER" >/dev/null 2>&1 || true
  token="$(incus config trust add "$PROVIDER_USER" --restricted --projects orbs --quiet)"
  sudo -iu "$PROVIDER_USER" incus remote add orbs-host https://127.0.0.1:8443 --token "$token" --accept-certificate >/dev/null
  sudo -iu "$PROVIDER_USER" incus remote switch orbs-host
fi

sed -E "s/^User=.*/User=$PROVIDER_USER/; /^SupplementaryGroups=/d; s#^ExecStart=/usr/local/bin/amp#ExecStart=$home/.amp/bin/amp#" \
  setup/amp-orb-provider.service > /etc/systemd/system/amp-orb-provider.service
systemctl daemon-reload
systemctl restart amp-orb-provider

install -m 755 setup/orb-cleanup.sh /usr/local/bin/orb-cleanup
install -m 644 setup/orb-cleanup.service setup/orb-cleanup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now orb-cleanup.timer >/dev/null

echo "Locked down."
