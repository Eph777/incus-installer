#!/usr/bin/env bash
set -euo pipefail

# ufw translates its output, which is parsed below
export LC_ALL=C

BRIDGE=lxdbr0
VM_CREATED=no

die() {
  echo "$*" >&2
  exit 1
}

if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root (try: sudo $0)"
fi

if ! command -v lxc >/dev/null; then
  die "LXD is not installed (try: snap install lxd, then lxd init)"
fi

on_exit() {
  local status=$?
  if [[ $status -ne 0 && $VM_CREATED == "yes" ]]; then
    echo "Setup stopped before finishing, so $VM is only partly configured." >&2
    echo "To remove it and start again: lxc delete $VM --force" >&2
  fi
}
trap on_exit EXIT

ask() {
  local var=$1 prompt=$2 default=${3:-} reply
  if [[ -n $default ]]; then
    read -rp "$prompt [$default]: " reply
  else
    read -rp "$prompt: " reply
  fi
  printf -v "$var" '%s' "${reply:-$default}"
}

ask_valid() {
  local var=$1 prompt=$2 default=$3 check=$4
  while true; do
    ask "$var" "$prompt" "$default"
    if "$check" "${!var}"; then
      return 0
    fi
  done
}

is_ipv4() {
  [[ $1 =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]] || return 1
  local octet
  for octet in ${1//./ }; do
    if ((octet > 255)); then
      return 1
    fi
  done
}

ip_to_int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  echo $(((a << 24) | (b << 16) | (c << 8) | d))
}

int_to_ip() {
  echo "$((($1 >> 24) & 255)).$((($1 >> 16) & 255)).$((($1 >> 8) & 255)).$(($1 & 255))"
}

ip_taken() {
  grep -Fxq "$1" <<<"$USED_IPS"
}

next_free_ip() {
  local n
  for ((n = NETWORK + 10; n < BROADCAST; n++)); do
    if ! ip_taken "$(int_to_ip "$n")"; then
      int_to_ip "$n"
      return 0
    fi
  done
}

# USED_PORTS holds single ports and ranges such as 4000-4999
port_taken() {
  local entry
  for entry in $USED_PORTS; do
    if (($1 >= ${entry%-*} && $1 <= ${entry#*-})); then
      return 0
    fi
  done
  return 1
}

next_free_port() {
  local port=$1
  while port_taken "$port"; do
    port=$((port + 1))
  done
  echo "$port"
}

to_mib() {
  local size=${1%?iB}
  if [[ $1 == *GiB ]]; then
    size=$((size * 1024))
  fi
  echo "$size"
}

check_name() {
  if [[ ! $1 =~ ^[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    echo "Use letters, numbers and hyphens, starting with a letter."
    return 1
  fi
  if lxc info "$1" >/dev/null 2>&1; then
    echo "An instance named $1 already exists."
    return 1
  fi
}

check_user() {
  if [[ ! $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "Use lowercase letters, numbers, hyphens and underscores."
    return 1
  fi
  if [[ $1 == "root" || $1 == "ubuntu" ]]; then
    echo "$1 already exists in the VM, choose another name."
    return 1
  fi
}

check_version() {
  if [[ ! $1 =~ ^[0-9]{2}\.[0-9]{2}$ ]]; then
    echo "Use a version like 24.04."
    return 1
  fi
}

check_size() {
  if [[ ! $1 =~ ^[1-9][0-9]*(MiB|GiB)$ ]]; then
    echo "Use a size like 4GiB or 512MiB."
    return 1
  fi
}

check_ram() {
  check_size "$1" || return 1
  if (($(to_mib "$1") >= TOTAL_MIB)); then
    echo "The server only has $TOTAL_MIB MiB of RAM."
    return 1
  fi
}

check_cpus() {
  if [[ ! $1 =~ ^[1-9][0-9]*$ ]] || (($1 > $(nproc))); then
    echo "Use a number from 1 to $(nproc)."
    return 1
  fi
}

check_vm_ip() {
  if ! is_ipv4 "$1"; then
    echo "That is not a valid IP address."
    return 1
  fi
  local ip_int
  ip_int=$(ip_to_int "$1")
  if ((ip_int <= NETWORK || ip_int >= BROADCAST)); then
    echo "The IP must be inside $BRIDGE_CIDR."
    return 1
  fi
  if ip_taken "$1"; then
    echo "$1 is already used."
    return 1
  fi
}

check_server_ip() {
  if ! grep -Fxq "$1" <<<"$SERVER_IPS"; then
    echo "$1 is not on this server. Addresses found:" $SERVER_IPS
    return 1
  fi
}

check_ssh_port() {
  if [[ ! $1 =~ ^[1-9][0-9]{0,4}$ ]] || (($1 > 65535)); then
    echo "Use a port from 1 to 65535."
    return 1
  fi
  if port_taken "$1"; then
    echo "Port $1 is already used on this server."
    return 1
  fi
}

ask_password() {
  local first second
  while true; do
    IFS= read -rsp "Password for $VM_USER (empty to generate one): " first
    echo
    if [[ -z $first ]]; then
      VM_PASSWORD=$(openssl rand -base64 18)
      PASSWORD_GENERATED=yes
      return 0
    fi
    if ((${#first} < 16)); then
      echo "Use at least 16 characters, because this port is open to the internet."
      continue
    fi
    IFS= read -rsp "Confirm the password: " second
    echo
    if [[ $first == "$second" ]]; then
      VM_PASSWORD=$first
      PASSWORD_GENERATED=no
      return 0
    fi
    echo "The passwords don't match."
  done
}

BRIDGE_CIDR=$(lxc network get "$BRIDGE" ipv4.address 2>/dev/null || true)
if [[ ! $BRIDGE_CIDR =~ ^([0-9.]+)/([0-9]+)$ ]]; then
  die "Bridge $BRIDGE has no IPv4 subnet. Has 'lxd init' been run?"
fi
GATEWAY=${BASH_REMATCH[1]}
PREFIX=${BASH_REMATCH[2]}
MASK=$(((0xFFFFFFFF << (32 - PREFIX)) & 0xFFFFFFFF))
NETWORK=$(($(ip_to_int "$GATEWAY") & MASK))
BROADCAST=$((NETWORK | (~MASK & 0xFFFFFFFF)))

USED_IPS=$GATEWAY
USED_PORTS=$(ss -Htln | awk '{print $4}' | sed 's/.*://' | tr '\n' ' ')
for instance in $(lxc list -c n --format csv); do
  devices=$(lxc config device show "$instance")
  USED_IPS+=$'\n'$(sed -n 's/^ *ipv4.address: //p' <<<"$devices")
  USED_PORTS+=" "$(sed -n 's/^ *listen: [a-z]*:.*:\([0-9,-]*\)$/\1/p' <<<"$devices" | tr ',\n' '  ')
done
USED_IPS+=$'\n'$(lxc list -c 4 --format csv | grep -oE '([0-9]+\.){3}[0-9]+' || true)

SERVER_IPS=$(ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1)
DEFAULT_SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' || true)
TOTAL_MIB=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
AVAILABLE_MIB=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)
POOL=$(lxc profile device get default root pool)

echo "Server: $AVAILABLE_MIB MiB of RAM available out of $TOTAL_MIB MiB, $(nproc) CPUs"
echo "Storage pool $POOL:"
lxc storage info "$POOL" | grep -E 'space used|total space' || true
echo "Existing instances:"
lxc list
echo

ask_valid VM "VM name" "" check_name
ask_valid VM_USER "SSH username" "" check_user
ask_password
ask_valid VERSION "Ubuntu version" "24.04" check_version
ask_valid RAM "RAM" "4GiB" check_ram
ask_valid CPUS "CPUs" "2" check_cpus
ask_valid DISK "Disk" "20GiB" check_size
ask_valid VM_IP "VM IP (inside $BRIDGE_CIDR)" "$(next_free_ip)" check_vm_ip
ask_valid SSH_PORT "SSH port on the server" "$(next_free_port 2222)" check_ssh_port
ask_valid SERVER_IP "Server IP to listen on" "$DEFAULT_SERVER_IP" check_server_ip
ask VM_SUDO "Give $VM_USER admin rights (sudo) inside the VM? (y/N)" "n"

cat <<EOF

Name:      $VM
Image:     ubuntu:$VERSION
RAM:       $RAM
CPUs:      $CPUS
Disk:      $DISK
VM IP:     $VM_IP
SSH user:  $VM_USER
SSH port:  $SERVER_IP:$SSH_PORT -> $VM_IP:22

EOF
ask CONFIRM "Create this VM? (y/N)" "n"
if [[ ! $CONFIRM =~ ^[yY] ]]; then
  echo "Nothing was created."
  exit 0
fi

lxc init "ubuntu:$VERSION" "$VM" --vm -c limits.memory="$RAM" -c limits.cpu="$CPUS"
VM_CREATED=yes
lxc config device override "$VM" root size="$DISK"
lxc config device override "$VM" eth0 ipv4.address="$VM_IP"
lxc config device add "$VM" ssh-forward proxy \
  listen=tcp:"$SERVER_IP":"$SSH_PORT" \
  connect=tcp:"$VM_IP":22 \
  nat=true
lxc start "$VM"

echo "Waiting for the VM to boot..."
attempts=0
until lxc exec "$VM" -- true 2>/dev/null; do
  attempts=$((attempts + 1))
  if ((attempts >= 90)); then
    die "The VM did not boot within 3 minutes (see: lxc info $VM --show-log)"
  fi
  sleep 2
done
# cloud-init exits with 2 on recoverable errors, which don't stop the setup
lxc exec "$VM" -- cloud-init status --wait >/dev/null || true

echo "Creating user $VM_USER..."
lxc exec "$VM" -- useradd -m -s /bin/bash "$VM_USER"
printf '%s:%s\n' "$VM_USER" "$VM_PASSWORD" | lxc exec "$VM" -- chpasswd
if [[ $VM_SUDO =~ ^[yY] ]]; then
  lxc exec "$VM" -- usermod -aG sudo "$VM_USER"
fi

# Ubuntu cloud images block password login, so allow it for this user only.
# /run/sshd doesn't exist until SSH has started once, and sshd -t needs it.
lxc exec "$VM" -- sh -c "printf '\nMatch User $VM_USER\n    PasswordAuthentication yes\n' >> /etc/ssh/sshd_config && mkdir -p /run/sshd && sshd -t && systemctl restart ssh"

echo "Installing fail2ban..."
lxc exec "$VM" -- sh -c "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban"

if command -v ufw >/dev/null && [[ "$(ufw status)" == *"Status: active"* ]]; then
  ufw route allow proto tcp to "$VM_IP" port 22
fi

if ! timeout 5 bash -c "exec 3<>/dev/tcp/$VM_IP/22"; then
  echo "Warning: SSH is not answering on $VM_IP:22 yet." >&2
fi
sleep 3
if ! lxc exec "$VM" -- fail2ban-client status sshd >/dev/null 2>&1; then
  echo "Warning: fail2ban is not watching SSH (check: lxc exec $VM -- fail2ban-client status sshd)." >&2
fi

echo
echo "$VM is ready. Connect with:"
echo
echo "  ssh -p $SSH_PORT $VM_USER@$SERVER_IP"
echo
if [[ $PASSWORD_GENERATED == "yes" ]]; then
  echo "Generated password (shown only once): $VM_PASSWORD"
  echo
fi
echo "If the server's public IP is different from $SERVER_IP, connect to the public IP instead."
echo "If your hosting provider has a firewall, allow TCP port $SSH_PORT there."
