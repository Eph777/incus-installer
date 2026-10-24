#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (try: sudo $0)" >&2
  exit 1
fi

. /etc/os-release
if [[ "$ID" != "ubuntu" ]]; then
  echo "This script supports Ubuntu only (detected: $ID)" >&2
  exit 1
fi

apt-get update
apt-get install -y curl ca-certificates

mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc

cat > /etc/apt/sources.list.d/zabbly-incus-stable.sources <<EOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: ${VERSION_CODENAME}
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF

apt-get update

if dpkg-query -W -f='${Status}' incus 2>/dev/null | grep -q "install ok installed"; then
  old_version=$(dpkg-query -W -f='${Version}' incus)
  echo "Incus $old_version is already installed, checking for updates..."
  apt-get install -y --only-upgrade incus
  new_version=$(dpkg-query -W -f='${Version}' incus)
  if [[ "$old_version" == "$new_version" ]]; then
    echo "Incus is already up to date ($new_version)."
  else
    echo "Incus updated: $old_version -> $new_version"
  fi
else
  apt-get install -y incus
  echo "Incus $(dpkg-query -W -f='${Version}' incus) installed. Next step: incus admin init"
fi
