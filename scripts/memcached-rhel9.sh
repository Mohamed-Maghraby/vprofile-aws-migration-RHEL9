#!/bin/bash

set -Eeuo pipefail

trap 'echo "ERROR: Script failed at line ${LINENO}." >&2' ERR

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root:"
    echo "sudo bash $0"
    exit 1
fi

MEMCACHED_PORT="${MEMCACHED_PORT:-11211}"
MEMCACHED_USER="${MEMCACHED_USER:-memcached}"
MEMCACHED_MEMORY_MB="${MEMCACHED_MEMORY_MB:-64}"
MEMCACHED_MAX_CONNECTIONS="${MEMCACHED_MAX_CONNECTIONS:-1024}"

echo "========================================"
echo "Installing Memcached"
echo "========================================"

dnf install -y memcached

echo "========================================"
echo "Configuring Memcached"
echo "========================================"

cat > /etc/sysconfig/memcached <<MEMCACHED_CONFIG
PORT="${MEMCACHED_PORT}"
USER="${MEMCACHED_USER}"
MAXCONN="${MEMCACHED_MAX_CONNECTIONS}"
CACHESIZE="${MEMCACHED_MEMORY_MB}"
OPTIONS="-l 0.0.0.0 -U 0"
MEMCACHED_CONFIG

echo "========================================"
echo "Starting and enabling Memcached"
echo "========================================"

systemctl enable --now memcached
systemctl restart memcached

echo "Waiting for Memcached..."

for attempt in {1..20}; do
    if ss -lnt | grep -q ":${MEMCACHED_PORT}"; then
        break
    fi

    if [[ "${attempt}" -eq 20 ]]; then
        echo "Memcached did not become ready."
        systemctl --no-pager --full status memcached || true
        journalctl -u memcached --no-pager -n 100 || true
        exit 1
    fi

    sleep 1
done

echo "========================================"
echo "Configuring firewalld when active"
echo "========================================"

if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${MEMCACHED_PORT}/tcp"
    firewall-cmd --reload
else
    echo "Firewalld is inactive."
    echo "AWS Security Groups must control access to TCP port ${MEMCACHED_PORT}."
fi

echo "========================================"
echo "Testing Memcached"
echo "========================================"

MEMCACHED_RESPONSE="$(
    timeout 5 bash -c "
        exec 3<>/dev/tcp/127.0.0.1/${MEMCACHED_PORT}
        printf 'version\r\n' >&3
        IFS= read -r response <&3
        printf '%s' \"\${response}\"
    "
)"

echo "Memcached response: ${MEMCACHED_RESPONSE}"

if [[ "${MEMCACHED_RESPONSE}" != VERSION* ]]; then
    echo "Memcached did not return a valid VERSION response."
    exit 1
fi

echo "========================================"
echo "Verifying service configuration"
echo "========================================"

systemctl is-active --quiet memcached
systemctl is-enabled --quiet memcached

ss -lntp | grep ":${MEMCACHED_PORT}"

if ss -lunp | grep -q ":${MEMCACHED_PORT}"; then
    echo "ERROR: Memcached UDP is still enabled."
    exit 1
else
    echo "Memcached UDP is disabled."
fi

echo "========================================"
echo "Memcached deployment completed"
echo "TCP port: ${MEMCACHED_PORT}"
echo "UDP: disabled"
echo "Memory: ${MEMCACHED_MEMORY_MB} MB"
echo "Maximum connections: ${MEMCACHED_MAX_CONNECTIONS}"
echo "========================================"
