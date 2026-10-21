#!/usr/bin/env bash
# Configure an offline PVE root for ifupdown2, preserving the previous files.
set -euo pipefail
[[ $# == 4 ]] || { echo "Usage: $0 ROOT ADDRESS/PREFIX GATEWAY INTERFACE" >&2; exit 2; }
root=${1%/}
address=$2
gateway=$3
interface=$4
[[ -f $root/etc/debian_version && -f $root/usr/sbin/ifreload ]] || {
  echo "Not an offline Debian/PVE root with ifupdown2: $root" >&2; exit 1;
}
[[ $interface =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || exit 2
python3 - "$address" "$gateway" <<'PY'
import ipaddress, sys
address = ipaddress.IPv4Interface(sys.argv[1])
gateway = ipaddress.IPv4Address(sys.argv[2])
assert gateway in address.network, 'Gateway must be on the management subnet'
PY

backup=$root/var/backups/pve-uefi-network
mkdir -p "$backup" "$root/etc/systemd/system/multi-user.target.wants"
chmod 700 "$backup"
for name in interfaces resolv.conf; do
  source=$root/etc/$name
  [[ $name != interfaces ]] || source=$root/etc/network/interfaces
  if [[ ! -e $backup/$name && ! -L $backup/$name ]]; then
    cp -a "$source" "$backup/$name"
  fi
done

cat > "$root/etc/network/interfaces" <<EOF
# PVE UEFI management bridge; previous configuration is in /var/backups/pve-uefi-network.
auto lo
iface lo inet loopback

iface $interface inet manual

auto vmbr0
iface vmbr0 inet static
    address $address
    gateway $gateway
    bridge-ports $interface
    bridge-stp off
    bridge-fd 0

source /etc/network/interfaces.d/*
EOF

# Netplan/networkd must not compete with the PVE-managed bridge.
for unit in systemd-networkd.service systemd-networkd-wait-online.service; do
  target=$root/etc/systemd/system/$unit
  if [[ ( -e $target || -L $target ) && ! -e $backup/$unit && ! -L $backup/$unit ]]; then
    cp -a "$target" "$backup/$unit"
  fi
  rm -f "$target"
  ln -s /dev/null "$target"
done
ln -sfn /usr/lib/systemd/system/networking.service \
  "$root/etc/systemd/system/multi-user.target.wants/networking.service"

# Avoid a dangling resolver stub after removing networkd as the link manager.
rm -f "$root/etc/resolv.conf"
printf 'nameserver 9.9.9.9\nnameserver 1.1.1.1\n' > "$root/etc/resolv.conf"
echo "Configured vmbr0 on $interface at $address (gateway $gateway)"
