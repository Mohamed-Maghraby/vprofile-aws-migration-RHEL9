#!/bin/bash

set -Eeuo pipefail

trap 'echo "ERROR: Script failed at line ${LINENO}." >&2' ERR

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root:"
    echo "sudo bash $0"
    exit 1
fi

TOMCAT_VERSION="${TOMCAT_VERSION:-9.0.120}"
TOMCAT_HOME="/usr/local/tomcat"
TOMCAT_ARCHIVE="apache-tomcat-${TOMCAT_VERSION}.tar.gz"
TOMCAT_URL="https://archive.apache.org/dist/tomcat/tomcat-9/v${TOMCAT_VERSION}/bin/${TOMCAT_ARCHIVE}"

SOURCE_REPOSITORY="https://github.com/abdelrahmanonline4/sourcecodeseniorwr.git"
SOURCE_BRANCH="Master"
SOURCE_DIRECTORY="/opt/vprofile-source"

APPLICATION_PROPERTIES="${SOURCE_DIRECTORY}/src/main/resources/application.properties"
WAR_FILE="${SOURCE_DIRECTORY}/target/vprofile-v2.war"

DB_HOST="${DB_HOST:-db.vprofile.internal}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-accounts}"
DB_USER="${DB_USER:-admin}"
DB_PASSWORD="${DB_PASSWORD:-admin123}"

CACHE_HOST="${CACHE_HOST:-cache.vprofile.internal}"
CACHE_PORT="${CACHE_PORT:-11211}"

RABBITMQ_HOST="${RABBITMQ_HOST:-mq.vprofile.internal}"
RABBITMQ_PORT="${RABBITMQ_PORT:-5672}"
RABBITMQ_USER="${RABBITMQ_USER:-test}"
RABBITMQ_PASSWORD="${RABBITMQ_PASSWORD:-test}"

SKIP_MEMCACHED_CHECK="${SKIP_MEMCACHED_CHECK:-false}"

echo "========================================"
echo "Installing Java, Maven, Git and tools"
echo "========================================"

dnf install -y \
    java-17-openjdk-devel \
    git \
    maven \
    curl \
    tar

JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"

echo "JAVA_HOME=${JAVA_HOME}"

java -version
javac -version
mvn -version

echo "========================================"
echo "Checking internal DNS"
echo "========================================"

getent hosts "${DB_HOST}"
getent hosts "${RABBITMQ_HOST}"

if [[ "${SKIP_MEMCACHED_CHECK}" != "true" ]]; then
    getent hosts "${CACHE_HOST}"
else
    echo "Skipping Memcached DNS check."
fi

check_port() {
    local host="$1"
    local port="$2"
    local service="$3"

    echo "Checking ${service}: ${host}:${port}"

    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}"; then
        echo "${service} is reachable."
    else
        echo "${service} is not reachable."
        return 1
    fi
}

echo "========================================"
echo "Checking backend connectivity"
echo "========================================"

check_port "${DB_HOST}" "${DB_PORT}" "MariaDB"
check_port "${RABBITMQ_HOST}" "${RABBITMQ_PORT}" "RabbitMQ"

if [[ "${SKIP_MEMCACHED_CHECK}" == "true" ]]; then
    echo "Skipping Memcached connectivity check."
    echo "Cache functionality will not work until Memcached is running."
else
    check_port "${CACHE_HOST}" "${CACHE_PORT}" "Memcached"
fi

echo "========================================"
echo "Downloading Apache Tomcat"
echo "========================================"

cd /tmp

rm -f "${TOMCAT_ARCHIVE}"

curl \
    --fail \
    --location \
    "${TOMCAT_URL}" \
    --output "${TOMCAT_ARCHIVE}"

echo "========================================"
echo "Creating the Tomcat user"
echo "========================================"

if ! id tomcat >/dev/null 2>&1; then
    useradd \
        --system \
        --home-dir "${TOMCAT_HOME}" \
        --shell /sbin/nologin \
        tomcat
fi

echo "========================================"
echo "Installing Apache Tomcat"
echo "========================================"

systemctl stop tomcat >/dev/null 2>&1 || true

rm -rf "${TOMCAT_HOME}"
mkdir -p "${TOMCAT_HOME}"

tar \
    --extract \
    --gzip \
    --file="/tmp/${TOMCAT_ARCHIVE}" \
    --directory="${TOMCAT_HOME}" \
    --strip-components=1

chmod +x "${TOMCAT_HOME}/bin/"*.sh
chown -R tomcat:tomcat "${TOMCAT_HOME}"

echo "========================================"
echo "Creating the Tomcat systemd service"
echo "========================================"

cat > /etc/systemd/system/tomcat.service <<TOMCAT_SERVICE
[Unit]
Description=Apache Tomcat 9 Web Application Container
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

User=tomcat
Group=tomcat

Environment="JAVA_HOME=${JAVA_HOME}"
Environment="CATALINA_HOME=${TOMCAT_HOME}"
Environment="CATALINA_BASE=${TOMCAT_HOME}"
Environment="CATALINA_OPTS=-Xms128M -Xmx384M -server"
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djava.security.egd=file:/dev/./urandom"

ExecStart=${TOMCAT_HOME}/bin/catalina.sh run

Restart=on-failure
RestartSec=5
SuccessExitStatus=143

LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
TOMCAT_SERVICE

systemctl daemon-reload

echo "========================================"
echo "Downloading the VProfile source code"
echo "========================================"

rm -rf "${SOURCE_DIRECTORY}"

git clone \
    --branch "${SOURCE_BRANCH}" \
    --single-branch \
    "${SOURCE_REPOSITORY}" \
    "${SOURCE_DIRECTORY}"

if [[ ! -f "${APPLICATION_PROPERTIES}" ]]; then
    echo "application.properties was not found:"
    echo "${APPLICATION_PROPERTIES}"
    exit 1
fi

echo "========================================"
echo "Writing the AWS application configuration"
echo "========================================"

cat > "${APPLICATION_PROPERTIES}" <<APP_PROPERTIES
# JDBC configuration
jdbc.driverClassName=com.mysql.jdbc.Driver
jdbc.url=jdbc:mysql://${DB_HOST}:${DB_PORT}/${DB_NAME}?useUnicode=true&characterEncoding=UTF-8&zeroDateTimeBehavior=convertToNull
jdbc.username=${DB_USER}
jdbc.password=${DB_PASSWORD}

# Memcached configuration
memcached.active.host=${CACHE_HOST}
memcached.active.port=${CACHE_PORT}
memcached.standBy.host=${CACHE_HOST}
memcached.standBy.port=${CACHE_PORT}

# RabbitMQ configuration
rabbitmq.address=${RABBITMQ_HOST}
rabbitmq.port=${RABBITMQ_PORT}
rabbitmq.username=${RABBITMQ_USER}
rabbitmq.password=${RABBITMQ_PASSWORD}

# Elasticsearch configuration
# Elasticsearch is skipped in this deployment.
elasticsearch.host=search.vprofile.internal
elasticsearch.port=9300
elasticsearch.cluster=vprofile
elasticsearch.node=vprofilenode
APP_PROPERTIES

echo "Application configuration:"

grep -E \
    "jdbc.url|jdbc.username|memcached.active.host|rabbitmq.address|rabbitmq.username|elasticsearch.host" \
    "${APPLICATION_PROPERTIES}"

echo "========================================"
echo "Building the VProfile WAR file"
echo "========================================"

export JAVA_HOME
export PATH="${JAVA_HOME}/bin:${PATH}"

cd "${SOURCE_DIRECTORY}"

mvn --batch-mode clean package -DskipTests

if [[ ! -f "${WAR_FILE}" ]]; then
    echo "WAR file was not generated:"
    echo "${WAR_FILE}"
    exit 1
fi

ls -lh "${WAR_FILE}"

echo "========================================"
echo "Deploying the WAR file"
echo "========================================"

rm -rf "${TOMCAT_HOME}/webapps/"*

install \
    -o tomcat \
    -g tomcat \
    -m 0644 \
    "${WAR_FILE}" \
    "${TOMCAT_HOME}/webapps/ROOT.war"

chown -R tomcat:tomcat "${TOMCAT_HOME}"

echo "========================================"
echo "Configuring firewalld when active"
echo "========================================"

if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port=8080/tcp
    firewall-cmd --reload
else
    echo "Firewalld is inactive."
    echo "AWS Security Groups must control access to TCP port 8080."
fi

echo "========================================"
echo "Starting Tomcat"
echo "========================================"

systemctl enable --now tomcat

echo "Waiting for the VProfile application..."

APPLICATION_READY="false"

for attempt in {1..60}; do
    HTTP_STATUS="$(
        curl \
            --silent \
            --output /dev/null \
            --write-out '%{http_code}' \
            http://127.0.0.1:8080/login || true
    )"

    if [[ "${HTTP_STATUS}" == "200" ]]; then
        APPLICATION_READY="true"
        break
    fi

    echo "Attempt ${attempt}/60: HTTP status ${HTTP_STATUS}"
    sleep 2
done

if [[ "${APPLICATION_READY}" != "true" ]]; then
    echo "The VProfile application did not become ready."

    systemctl --no-pager --full status tomcat || true
    journalctl --unit=tomcat --no-pager --lines=150 || true

    exit 1
fi

echo "========================================"
echo "Verifying Tomcat"
echo "========================================"

systemctl is-active --quiet tomcat
systemctl is-enabled --quiet tomcat

ss -lntp | grep ':8080'

LOGIN_STATUS="$(
    curl \
        --silent \
        --output /dev/null \
        --write-out '%{http_code}' \
        http://127.0.0.1:8080/login
)"

ROOT_STATUS="$(
    curl \
        --silent \
        --output /dev/null \
        --write-out '%{http_code}' \
        http://127.0.0.1:8080/
)"

echo "Login page HTTP status: ${LOGIN_STATUS}"
echo "Root page HTTP status: ${ROOT_STATUS}"

if [[ "${LOGIN_STATUS}" != "200" ]]; then
    echo "The login page is not healthy."
    exit 1
fi

if [[ "${ROOT_STATUS}" != "302" && "${ROOT_STATUS}" != "200" ]]; then
    echo "The application root returned an unexpected status."
    exit 1
fi

echo "========================================"
echo "Tomcat deployment completed"
echo "Tomcat version: ${TOMCAT_VERSION}"
echo "Java home: ${JAVA_HOME}"
echo "Application port: 8080"
echo "Health-check path: /login"
echo "========================================"
