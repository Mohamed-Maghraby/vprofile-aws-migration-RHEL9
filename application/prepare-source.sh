#!/bin/bash

set -Eeuo pipefail

trap 'echo "ERROR: Application preparation failed at line ${LINENO}." >&2' ERR

SOURCE_REPOSITORY="${SOURCE_REPOSITORY:-https://github.com/abdelrahmanonline4/sourcecodeseniorwr.git}"
SOURCE_BRANCH="${SOURCE_BRANCH:-Master}"
SOURCE_DIRECTORY="${SOURCE_DIRECTORY:-/opt/vprofile-source}"

SCRIPT_DIRECTORY="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" &&
    pwd
)"

PRODUCER_OVERRIDE="${SCRIPT_DIRECTORY}/overrides/ProducerServiceImpl.java"
RABBITMQ_OVERRIDE="${SCRIPT_DIRECTORY}/overrides/appconfig-rabbitmq.xml"

APPLICATION_PROPERTIES="${SOURCE_DIRECTORY}/src/main/resources/application.properties"
POM_FILE="${SOURCE_DIRECTORY}/pom.xml"

require_variable() {
    local variable_name="$1"

    if [[ -z "${!variable_name:-}" ]]; then
        echo "Required environment variable is missing: ${variable_name}" >&2
        exit 1
    fi
}

require_variable DB_HOST
require_variable DB_NAME
require_variable DB_USER
require_variable DB_PASSWORD
require_variable CACHE_HOST
require_variable RABBITMQ_HOST
require_variable RABBITMQ_PORT
require_variable RABBITMQ_USER
require_variable RABBITMQ_PASSWORD

for required_file in \
    "${PRODUCER_OVERRIDE}" \
    "${RABBITMQ_OVERRIDE}"
do
    if [[ ! -f "${required_file}" ]]; then
        echo "Required override file not found: ${required_file}" >&2
        exit 1
    fi
done

echo "Cloning the VProfile application source..."

rm -rf "${SOURCE_DIRECTORY}"

git clone \
    --branch "${SOURCE_BRANCH}" \
    --single-branch \
    "${SOURCE_REPOSITORY}" \
    "${SOURCE_DIRECTORY}"

echo "Updating legacy RabbitMQ dependencies..."

python3 - "${POM_FILE}" <<'PYTHON'
from pathlib import Path
import sys

pom_path = Path(sys.argv[1])
content = pom_path.read_text(encoding="utf-8")

replacements = {
    "<version>1.7.1.RELEASE</version>":
        "<version>1.7.15.RELEASE</version>",

    "<version>4.0.2</version>":
        "<version>4.12.0</version>",
}

for old, new in replacements.items():
    count = content.count(old)

    if count != 1:
        raise RuntimeError(
            f"Expected exactly one occurrence of {old!r}, found {count}"
        )

    content = content.replace(old, new, 1)

pom_path.write_text(content, encoding="utf-8")
PYTHON

echo "Installing the Amazon MQ application overrides..."

install -m 0644 \
    "${PRODUCER_OVERRIDE}" \
    "${SOURCE_DIRECTORY}/src/main/java/com/visualpathit/account/service/ProducerServiceImpl.java"

install -m 0644 \
    "${RABBITMQ_OVERRIDE}" \
    "${SOURCE_DIRECTORY}/src/main/webapp/WEB-INF/appconfig-rabbitmq.xml"

echo "Creating application.properties with managed-service endpoints..."

umask 077

cat > "${APPLICATION_PROPERTIES}" <<PROPERTIES
# RDS MySQL
jdbc.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.url=jdbc:mysql://${DB_HOST}:3306/${DB_NAME}?useUnicode=true&characterEncoding=UTF-8&zeroDateTimeBehavior=CONVERT_TO_NULL&serverTimezone=UTC&sslMode=REQUIRED
jdbc.username=${DB_USER}
jdbc.password=${DB_PASSWORD}

# ElastiCache Memcached
memcached.active.host=${CACHE_HOST}
memcached.active.port=11211
memcached.standBy.host=${CACHE_HOST}
memcached.standBy.port=11211

# Amazon MQ for RabbitMQ
rabbitmq.address=${RABBITMQ_HOST}
rabbitmq.port=${RABBITMQ_PORT}
rabbitmq.username=${RABBITMQ_USER}
rabbitmq.password=${RABBITMQ_PASSWORD}

# Elasticsearch is not deployed in this Terraform environment.
# Search-related functionality may remain unavailable.
elasticsearch.host=127.0.0.1
elasticsearch.port=9300
elasticsearch.cluster=vprofile
elasticsearch.node=vprofilenode
PROPERTIES

chmod 600 "${APPLICATION_PROPERTIES}"

echo "Building the VProfile WAR..."

cd "${SOURCE_DIRECTORY}"

mvn \
    --batch-mode \
    --no-transfer-progress \
    -Dmaven.test.skip=true \
    clean package

WAR_FILE="${SOURCE_DIRECTORY}/target/vprofile-v2.war"

if [[ ! -s "${WAR_FILE}" ]]; then
    echo "WAR file was not generated: ${WAR_FILE}" >&2
    exit 1
fi

echo "Application preparation completed successfully."
echo "WAR file: ${WAR_FILE}"
