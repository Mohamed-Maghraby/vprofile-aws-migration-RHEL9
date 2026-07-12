#!/bin/bash

set -Eeuo pipefail

trap 'echo "ERROR: Script failed at line ${LINENO}." >&2' ERR

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root:"
    echo "sudo bash $0"
    exit 1
fi

RABBITMQ_USER="${RABBITMQ_USER:-test}"
RABBITMQ_PASSWORD="${RABBITMQ_PASSWORD:-test}"
RABBITMQ_VHOST="${RABBITMQ_VHOST:-/}"

echo "========================================"
echo "Installing required packages"
echo "========================================"

dnf install -y ca-certificates curl logrotate

echo "========================================"
echo "Importing RabbitMQ signing keys"
echo "========================================"

rpm --import \
"https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc"

rpm --import \
"https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495BB49CC4BBE5B.key"

rpm --import \
"https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F4587F226208342.key"

echo "========================================"
echo "Configuring RabbitMQ repositories"
echo "========================================"

cat > /etc/yum.repos.d/rabbitmq.repo <<'RABBITMQ_REPOSITORY'
[modern-erlang]
name=modern-erlang-el9
baseurl=https://yum1.rabbitmq.com/erlang/el/9/$basearch
        https://yum2.rabbitmq.com/erlang/el/9/$basearch
enabled=1
repo_gpgcheck=1
gpgcheck=1
pkg_gpgcheck=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495BB49CC4BBE5B.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
type=rpm-md

[modern-erlang-noarch]
name=modern-erlang-el9-noarch
baseurl=https://yum1.rabbitmq.com/erlang/el/9/noarch
        https://yum2.rabbitmq.com/erlang/el/9/noarch
enabled=1
repo_gpgcheck=1
gpgcheck=1
pkg_gpgcheck=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495BB49CC4BBE5B.key
       https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
type=rpm-md

[rabbitmq-el9]
name=rabbitmq-el9
baseurl=https://yum2.rabbitmq.com/rabbitmq/el/9/$basearch
        https://yum1.rabbitmq.com/rabbitmq/el/9/$basearch
enabled=1
repo_gpgcheck=1
gpgcheck=1
pkg_gpgcheck=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F4587F226208342.key
       https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
type=rpm-md

[rabbitmq-el9-noarch]
name=rabbitmq-el9-noarch
baseurl=https://yum2.rabbitmq.com/rabbitmq/el/9/noarch
        https://yum1.rabbitmq.com/rabbitmq/el/9/noarch
enabled=1
repo_gpgcheck=1
gpgcheck=1
pkg_gpgcheck=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F4587F226208342.key
       https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
type=rpm-md
RABBITMQ_REPOSITORY

echo "========================================"
echo "Installing Erlang and RabbitMQ"
echo "========================================"

dnf clean all
dnf makecache
dnf install -y erlang rabbitmq-server

echo "========================================"
echo "Configuring RabbitMQ"
echo "========================================"

mkdir -p /etc/rabbitmq

cat > /etc/rabbitmq/rabbitmq.conf <<'RABBITMQ_CONFIG'
listeners.tcp.default = 5672
RABBITMQ_CONFIG

echo "========================================"
echo "Starting RabbitMQ"
echo "========================================"

systemctl enable --now rabbitmq-server

echo "Waiting for RabbitMQ..."

for attempt in {1..30}; do
    if rabbitmq-diagnostics -q ping >/dev/null 2>&1; then
        break
    fi

    if [[ "${attempt}" -eq 30 ]]; then
        echo "RabbitMQ did not become ready."
        systemctl --no-pager --full status rabbitmq-server || true
        journalctl -u rabbitmq-server --no-pager -n 100 || true
        exit 1
    fi

    sleep 2
done

echo "========================================"
echo "Creating the application user"
echo "========================================"

if rabbitmqctl list_users -q | awk '{print $1}' |
    grep -qx "${RABBITMQ_USER}"; then

    echo "RabbitMQ user already exists. Updating password."

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
    ".*" \
    ".*" \
    ".*"

echo "Removing the default guest user..."

rabbitmqctl delete_user guest >/dev/null 2>&1 || true

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

rabbitmqctl list_users
rabbitmqctl list_permissions -p "${RABBITMQ_VHOST}"

ss -lntp | grep ':5672'

echo "RabbitMQ version:"
rabbitmq-diagnostics server_version

echo "Erlang version:"
erl -noshell \
    -eval 'io:format("~s~n", [erlang:system_info(otp_release)]), halt().'

echo "========================================"
echo "RabbitMQ deployment completed"
echo "Application user: ${RABBITMQ_USER}"
echo "AMQP port: 5672"
echo "Virtual host: ${RABBITMQ_VHOST}"
echo "========================================"
