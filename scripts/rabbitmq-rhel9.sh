#!/bin/bash
et -Eeuo pipefail

trap 'echo "ERROR: Script failed at line ${LINENO}." >&2' ERR

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root:"
    echo "sudo RABBITMQ_PASSWORD='your-password' bash $0"
    exit 1
fi

RABBITMQ_USER="${RABBITMQ_USER:-test}"
RABBITMQ_PASSWORD="${RABBITMQ_PASSWORD:-}"
RABBITMQ_VHOST="${RABBITMQ_VHOST:-/}"

SWAP_FILE="${SWAP_FILE:-/swapfile}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
MIN_SWAP_MB="${MIN_SWAP_MB:-1024}"

if [[ -z "${RABBITMQ_PASSWORD}" ]]; then
    echo "RABBITMQ_PASSWORD must be provided."
    echo
    echo "Example:"
    echo "sudo RABBITMQ_PASSWORD='test' bash $0"
    exit 1
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
    echo "This repository configuration requires an x86_64 EC2 instance."
    echo "Detected architecture: $(uname -m)"
    exit 1
fi

ensure_swap() {
    local current_swap_mb

    current_swap_mb="$(free -m | awk '/^Swap:/ {print $2}')"

    echo "Current swap: ${current_swap_mb} MB"

    if (( current_swap_mb >= MIN_SWAP_MB )); then
        echo "Sufficient swap is already available."
        return
    fi

    echo "Creating persistent ${SWAP_SIZE} swap file..."

    if swapon --show=NAME --noheadings |
        awk '{$1=$1};1' |
        grep -Fxq "${SWAP_FILE}"; then

        echo "${SWAP_FILE} is already active."
    else
        if [[ ! -f "${SWAP_FILE}" ]]; then
            fallocate -l "${SWAP_SIZE}" "${SWAP_FILE}"
        fi

        chmod 600 "${SWAP_FILE}"
        mkswap -f "${SWAP_FILE}"
        swapon "${SWAP_FILE}"
    fi

    if ! grep -qF "${SWAP_FILE} none swap defaults 0 0" /etc/fstab; then
        echo "${SWAP_FILE} none swap defaults 0 0" >> /etc/fstab
    fi

    echo "Swap configuration:"
    swapon --show
    free -h
}

echo "========================================"
echo "Preparing memory for package installation"
echo "========================================"

ensure_swap

echo "========================================"
echo "Installing required packages"
echo "========================================"

dnf install -y ca-certificates curl logrotate

echo "========================================"
echo "Importing RabbitMQ signing keys"
echo "========================================"

rpm --import \
    'https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.as
c'

rpm --import \
    'https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495
BB49CC4BBE5B.key'

rpm --import \
    'https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F45
87F226208342.key'

echo "========================================"
echo "Configuring RabbitMQ repositories for RHEL 9"
echo "========================================"

cat > /etc/yum.repos.d/rabbitmq.repo <<'REPOSITORY'
[modern-erlang]
name=modern-erlang-el9
baseurl=https://yum1.rabbitmq.com/erlang/el/9/$basearch
        https://yum2.rabbitmq.com/erlang/el/9/$basearch
repo_gpgcheck=1
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E4
95BB49CC4BBE5B.key
gpgcheck=1
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
pkg_gpgcheck=1
autorefresh=1
type=rpm-md

[modern-erlang-noarch]
name=modern-erlang-el9-noarch
baseurl=https://yum1.rabbitmq.com/erlang/el/9/noarch
        https://yum2.rabbitmq.com/erlang/el/9/noarch
repo_gpgcheck=1
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E4
95BB49CC4BBE5B.key
       https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.
asc
gpgcheck=1
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
pkg_gpgcheck=1
autorefresh=1
type=rpm-md

[rabbitmq-el9]
name=rabbitmq-el9
baseurl=https://yum2.rabbitmq.com/rabbitmq/el/9/$basearch
        https://yum1.rabbitmq.com/rabbitmq/el/9/$basearch
repo_gpgcheck=1
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F
4587F226208342.key
       https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.
asc
gpgcheck=1
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
pkg_gpgcheck=1
autorefresh=1
type=rpm-md

[rabbitmq-el9-noarch]
name=rabbitmq-el9-noarch
baseurl=https://yum2.rabbitmq.com/rabbitmq/el/9/noarch
        https://yum1.rabbitmq.com/rabbitmq/el/9/noarch
repo_gpgcheck=1
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F
4587F226208342.key
       https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.
asc
gpgcheck=1
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
pkg_gpgcheck=1
autorefresh=1
type=rpm-md
REPOSITORY

echo "========================================"
echo "Installing Erlang and RabbitMQ"
echo "========================================"

# Do not run 'dnf makecache' here. It caused an OOM failure
# on the low-memory EC2 instance. DNF will retrieve only the
# metadata required for this installation.

dnf install -y \
    --setopt=install_weak_deps=False \
    erlang \
    rabbitmq-server

echo "========================================"
echo "Configuring RabbitMQ"
echo "========================================"

mkdir -p /etc/rabbitmq

cat > /etc/rabbitmq/rabbitmq.conf <<'RABBITMQ_CONFIG'
listeners.tcp.default = 5672
RABBITMQ_CONFIG

chown root:rabbitmq /etc/rabbitmq/rabbitmq.conf
chmod 640 /etc/rabbitmq/rabbitmq.conf

echo "========================================"
echo "Configuring the RabbitMQ file limit"
echo "========================================"

mkdir -p /etc/systemd/system/rabbitmq-server.service.d

cat > /etc/systemd/system/rabbitmq-server.service.d/limits.conf <<'LIMITS'
[Service]
LimitNOFILE=64000
LIMITS

systemctl daemon-reload

echo "========================================"
echo "Starting and enabling RabbitMQ"
echo "========================================"

systemctl enable --now rabbitmq-server

echo "Waiting for RabbitMQ to become ready..."

for attempt in {1..60}; do
    if rabbitmq-diagnostics -q ping >/dev/null 2>&1; then
        echo "RabbitMQ is ready."
        break
    fi

    if [[ "${attempt}" -eq 60 ]]; then
        echo "RabbitMQ did not become ready."

        systemctl --no-pager --full status rabbitmq-server || true
        journalctl -u rabbitmq-server --no-pager -n 150 || true

        exit 1
    fi

    echo "Attempt ${attempt}/60: waiting for RabbitMQ..."
    sleep 2
done

echo "========================================"
echo "Creating the RabbitMQ application user"
echo "========================================"

if rabbitmqctl list_users 2>/dev/null |
    awk 'NR > 1 {print $1}' |
    grep -Fxq "${RABBITMQ_USER}"; then

    echo "User ${RABBITMQ_USER} already exists."
    echo "Updating its password..."

    rabbitmqctl change_password \
        "${RABBITMQ_USER}" \
        "${RABBITMQ_PASSWORD}"
else
    rabbitmqctl add_user \
        "${RABBITMQ_USER}" \
        "${RABBITMQ_PASSWORD}"
fi

rabbitmqctl set_user_tags \
    "${RABBITMQ_USER}" \
    administrator

rabbitmqctl set_permissions \
    -p "${RABBITMQ_VHOST}" \
    "${RABBITMQ_USER}" \
    '.*' \
    '.*' \
    '.*'

if [[ "${RABBITMQ_USER}" != "guest" ]]; then
    echo "Removing the default guest user..."
    rabbitmqctl delete_user guest >/dev/null 2>&1 || true
fi

echo "========================================"
echo "Configuring firewalld when active"
echo "========================================"

if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port=5672/tcp
    firewall-cmd --reload
else
    echo "Firewalld is inactive."
    echo "AWS Security Groups must control access to TCP port 5672."
fi

echo "========================================"
echo "Verifying RabbitMQ"
echo "========================================"

rabbitmq-diagnostics -q ping

rabbitmqctl authenticate_user \
    "${RABBITMQ_USER}" \
    "${RABBITMQ_PASSWORD}"

echo
echo "RabbitMQ users:"
rabbitmqctl list_users

echo
echo "Permissions for virtual host ${RABBITMQ_VHOST}:"
rabbitmqctl list_permissions -p "${RABBITMQ_VHOST}"

echo
echo "TCP listener:"
ss -lntp | grep ':5672'

echo
echo "RabbitMQ version:"
rabbitmq-diagnostics server_version

echo
echo "Erlang/OTP version:"
erl -noshell \
    -eval 'io:format("~s~n", [erlang:system_info(otp_release)]), halt().'

echo
echo "Memory and swap status:"
free -h
swapon --show

echo "========================================"
echo "RabbitMQ deployment completed successfully"
echo "Application user: ${RABBITMQ_USER}"
echo "Virtual host: ${RABBITMQ_VHOST}"
echo "AMQP port: 5672"
echo "========================================"
