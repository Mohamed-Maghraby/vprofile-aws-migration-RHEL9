#!/bin/bash

set -Eeuo pipefail

trap 'echo "ERROR: Script failed at line ${LINENO}." >&2' ERR

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root:"
    echo "sudo bash $0"
    exit 1
fi

DB_NAME="${DB_NAME:-accounts}"
DB_USER="${DB_USER:-admin}"
DB_PASSWORD="${DB_PASSWORD:-admin123}"

SOURCE_REPOSITORY="https://github.com/abdelrahmanonline4/sourcecodeseniorwr.git"
SOURCE_BRANCH="Master"
SOURCE_DIRECTORY="/opt/sourcecodeseniorwr"
DATABASE_BACKUP="${SOURCE_DIRECTORY}/src/main/resources/db_backup.sql"

echo "========================================"
echo "Installing MariaDB and Git"
echo "========================================"

dnf install -y mariadb-server git

echo "========================================"
echo "Starting MariaDB"
echo "========================================"

systemctl enable --now mariadb

echo "========================================"
echo "Configuring network access"
echo "========================================"

mkdir -p /etc/my.cnf.d

cat > /etc/my.cnf.d/vprofile.cnf <<'MARIADB_CONFIG'
[mysqld]
bind-address=0.0.0.0
MARIADB_CONFIG

systemctl restart mariadb

echo "Waiting for MariaDB..."

for attempt in {1..30}; do
    if mariadb-admin -u root ping --silent >/dev/null 2>&1; then
        break
    fi

    if [[ "${attempt}" -eq 30 ]]; then
        echo "MariaDB did not become ready."
        systemctl --no-pager --full status mariadb || true
        journalctl -u mariadb --no-pager -n 100 || true
        exit 1
    fi

    sleep 2
done

echo "========================================"
echo "Securing MariaDB"
echo "========================================"

mariadb -u root <<'SQL'
DELETE FROM mysql.user WHERE User = '';

DROP DATABASE IF EXISTS test;

DELETE FROM mysql.db
WHERE Db = 'test'
   OR Db LIKE 'test\_%';

FLUSH PRIVILEGES;
SQL

echo "========================================"
echo "Creating database and application user"
echo "========================================"

mariadb -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
    CHARACTER SET utf8
    COLLATE utf8_general_ci;

DROP USER IF EXISTS '${DB_USER}'@'%';

CREATE USER '${DB_USER}'@'%'
    IDENTIFIED BY '${DB_PASSWORD}';

GRANT ALL PRIVILEGES
    ON \`${DB_NAME}\`.*
    TO '${DB_USER}'@'%';

FLUSH PRIVILEGES;
SQL

echo "========================================"
echo "Downloading application source"
echo "========================================"

rm -rf "${SOURCE_DIRECTORY}"

git clone --branch "${SOURCE_BRANCH}" --single-branch "${SOURCE_REPOSITORY}" "${SOURCE_DIRECTORY}"

if [[ ! -f "${DATABASE_BACKUP}" ]]; then
    echo "Database backup was not found:"
    echo "${DATABASE_BACKUP}"
    exit 1
fi

echo "========================================"
echo "Importing database backup"
echo "========================================"

mariadb -u root "${DB_NAME}" < "${DATABASE_BACKUP}"

echo "========================================"
echo "Configuring firewalld when active"
echo "========================================"

if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-service=mysql
    firewall-cmd --reload
else
    echo "Firewalld is inactive."
    echo "AWS Security Groups must control access to TCP port 3306."
fi

echo "========================================"
echo "Restarting and verifying MariaDB"
echo "========================================"

systemctl restart mariadb

mariadb -u root -e "
USE ${DB_NAME};
SHOW TABLES;
SELECT COUNT(*) AS users FROM user;
"

mariadb \
    --host=127.0.0.1 \
    --user="${DB_USER}" \
    --password="${DB_PASSWORD}" \
    --execute="USE ${DB_NAME}; SELECT COUNT(*) AS users FROM user;"

ss -lntp | grep ':3306'

echo "========================================"
echo "MariaDB deployment completed"
echo "Database: ${DB_NAME}"
echo "Application user: ${DB_USER}"
echo "Port: 3306"
echo "========================================"
