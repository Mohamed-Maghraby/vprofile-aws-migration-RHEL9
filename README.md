AWS Migration on RHEL 9

This repository documents the migration of the **VProfile Java web application** from an on-premises environment to AWS.

Every EC2 instance in this guide uses **Red Hat Enterprise Linux 9**.

The deployment uses:

- A custom Amazon VPC
- Two public and two private subnets across two Availability Zones
- An Internet Gateway
- NAT Gateways for private-instance outbound access
- Route 53 private DNS for service discovery
- RHEL 9 EC2 instances for MariaDB, RabbitMQ, Memcached, and Tomcat
- A temporary RHEL 9 bastion host
- An internet-facing Application Load Balancer
- Security-group-to-security-group access control
- Adapted copies of the original repository deployment scripts

> The repository's `Vagrantfile` and `nginx.sh` are not used. AWS Application Load Balancer replaces NGINX.

---

## Important lab design decision

The AWS account used for this lab has an **8-vCPU On-Demand EC2 quota**. A `t3.micro` and a `t3.small` both consume two vCPUs.

The lab therefore uses this sequence:

1. Run a temporary bastion host while deploying the three private backend servers.
2. Keep these four instances running:
   - Bastion
   - MariaDB
   - RabbitMQ
   - Memcached
3. After the backend servers are configured, **terminate the bastion**.
4. Launch the Tomcat instance in a public subnet with a public IPv4 address.
5. Use the Tomcat server as the temporary SSH jump host for the private backend servers.

This keeps the running total at four two-vCPU instances:

```text
MariaDB     2 vCPUs
RabbitMQ    2 vCPUs
Memcached   2 vCPUs
Tomcat      2 vCPUs
-------------------
Total       8 vCPUs
```

> Using the application server as a jump host is a quota-driven lab workaround. In production, keep Tomcat private and use a dedicated bastion, AWS Systems Manager Session Manager, or a VPN.

---

## Project status and limitations

| Component | Operating system | Placement | Status |
|---|---|---|---|
| MariaDB | RHEL 9 | Private subnet | Deployed |
| RabbitMQ | RHEL 9 | Private subnet | Deployed |
| Memcached | RHEL 9 | Private subnet | Deployed |
| Temporary bastion | RHEL 9 | Public subnet | Used during backend setup, then terminated |
| Tomcat/VProfile | RHEL 9 | Public subnet with public IPv4 | Deployed |
| Application Load Balancer | AWS managed | Two public subnets | Deployed |
| Route 53 private hosted zone | AWS managed | Associated with the VPC | Deployed |
| Elasticsearch | — | — | Intentionally skipped |
| Second Tomcat instance | — | — | Not deployed because of the vCPU quota |

The original assignment requests high availability across multiple Availability Zones. The ALB spans two AZs, but this quota-limited lab has only one Tomcat target. The application tier is therefore **not fully highly available**.

---

## Final architecture

```text
                                      Internet
                                         |
                     Internet-facing Application Load Balancer
                         Public AZ1                  Public AZ2
                                         |
                                  Target group :8080
                                         |
                          Tomcat / VProfile EC2, RHEL 9
                        Public subnet + public IPv4 address
                         SSH :22 only from administrator IP
                      App :8080 only from the ALB security group
                                         |
                 +-----------------------+-----------------------+
                 |                       |                       |
       db.vprofile.internal    mq.vprofile.internal    cache.vprofile.internal
          MariaDB :3306           RabbitMQ :5672          Memcached :11211
          RHEL 9 private          RHEL 9 private          RHEL 9 private

Administrative SSH after bastion deletion:
Administrator PC -> Tomcat public IP -> backend private IP
```

Elasticsearch is skipped. Features that require Elasticsearch may fail until a compatible service is deployed at `search.vprofile.internal:9300`.

---

## Deployment order

1. Create the VPC, subnets, route tables, Internet Gateway, and NAT Gateways.
2. Create the initial security groups.
3. Launch the temporary bastion.
4. Launch MariaDB, RabbitMQ, and Memcached in private subnets.
5. Use adapted RHEL 9 scripts to configure each backend.
6. Create Route 53 private DNS records.
7. Verify all backend services from inside the VPC.
8. Terminate the bastion to release two vCPUs.
9. Update security groups so Tomcat can be used as the jump host.
10. Launch Tomcat in a public subnet with a public IPv4 address.
11. Deploy VProfile using the adapted Tomcat script.
12. Create the target group and Application Load Balancer.
13. Validate the application through the ALB.

---

## Repository usage model

The original cloned scripts remain unchanged. Deployment changes are made only to copied files.

```text
/home/ec2-user/
├── vprofile-original/                 # Unmodified repository clone
│   ├── mariadb.sh
│   ├── rabbitmq.sh
│   ├── memcached.sh
│   ├── tomcat.sh
│   ├── nginx.sh                       # Not used
│   └── Vagrantfile                    # Not used
└── vprofile-deployment/               # Adapted AWS/RHEL 9 scripts
    ├── mariadb-rhel9.sh
    ├── rabbitmq-rhel9.sh
    ├── memcached-rhel9.sh
    └── tomcat-rhel9.sh
```

On each target server:

```bash
sudo dnf install -y git
cd ~
git clone -b Master https://github.com/abdelrahmanonline4/vprofile-test.git vprofile-original
mkdir -p ~/vprofile-deployment
```

Copy only the script required by that server, then replace the copied file with the corrected version in this README.

---

## Prerequisites

- AWS account with access to EC2, VPC, Route 53, and Elastic Load Balancing
- AWS Region: `eu-north-1`
- One EC2 key pair, for example `mykey.pem`
- Official RHEL 9 x86_64 AMI
- Your current public IPv4 address
- Infrastructure repository:

```text
https://github.com/abdelrahmanonline4/vprofile-test
```

- Application repository:

```text
https://github.com/abdelrahmanonline4/sourcecodeseniorwr
```

Lab credentials:

```text
MariaDB database: accounts
MariaDB user:     admin
MariaDB password: admin123
RabbitMQ user:    test
RabbitMQ password:test
```

> These credentials are only for this lab. Use AWS Secrets Manager, SSM Parameter Store, or another secret-management system in a real environment.

---

# Phase 1 — Networking

## 1. Create the VPC

```text
Name: EFE-Project01-VPC
IPv4 CIDR: 10.0.0.0/16
```

Enable:

```text
DNS resolution: enabled
DNS hostnames:  enabled
```

## 2. Create four subnets

| Name | CIDR | Type |
|---|---|---|
| `EFE-Project01-Pub-AZ1` | `10.0.1.0/24` | Public |
| `EFE-Project01-Pub-AZ2` | `10.0.2.0/24` | Public |
| `EFE-Project01-Private-AZ1` | `10.0.11.0/24` | Private |
| `EFE-Project01-Private-AZ2` | `10.0.12.0/24` | Private |

The AZ1 public/private pair must use the same Availability Zone. The AZ2 pair must use a different Availability Zone.

## 3. Create and attach the Internet Gateway

```text
Name: EFE-Project01-IGW
Attach to: EFE-Project01-VPC
```

## 4. Create the public route table

```text
Name: EFE-Project01-Public-RT
```

Routes:

```text
10.0.0.0/16 -> local
0.0.0.0/0   -> EFE-Project01-IGW
```

Associate it with:

```text
EFE-Project01-Pub-AZ1
EFE-Project01-Pub-AZ2
```

## 5. Create NAT Gateways

Create one NAT Gateway in each public subnet:

```text
EFE-Project01-NAT-AZ1 -> EFE-Project01-Pub-AZ1
EFE-Project01-NAT-AZ2 -> EFE-Project01-Pub-AZ2
```

Each NAT Gateway requires an Elastic IP.

> NAT Gateways and the ALB can generate charges. Delete them when the lab is no longer needed.

## 6. Create private route tables

### AZ1

```text
Name: EFE-Project01-Private-RT-AZ1
10.0.0.0/16 -> local
0.0.0.0/0   -> EFE-Project01-NAT-AZ1
Association  -> EFE-Project01-Private-AZ1
```

### AZ2

```text
Name: EFE-Project01-Private-RT-AZ2
10.0.0.0/16 -> local
0.0.0.0/0   -> EFE-Project01-NAT-AZ2
Association  -> EFE-Project01-Private-AZ2
```

---

# Phase 2 — Initial security groups

Create all security groups inside `EFE-Project01-VPC`.

## ALB security group

```text
Name: EFE-Project01-ALB-SG
Inbound: HTTP TCP 80 from 0.0.0.0/0
Outbound: All traffic
```

## Temporary bastion security group

```text
Name: EFE-Project01-Bastion-SG
Inbound: SSH TCP 22 from YOUR_PUBLIC_IP/32
Outbound: All traffic
```

## Tomcat security group

Create it now, even though Tomcat will be launched later.

```text
Name: EFE-Project01-Tomcat-SG
Inbound: Custom TCP 8080 from EFE-Project01-ALB-SG
Outbound: All traffic
```

Do not add public SSH access yet. It will be added after the bastion is terminated.

## MariaDB security group

```text
Name: EFE-Project01-MariaDB-SG
Inbound: MySQL/Aurora TCP 3306 from EFE-Project01-Tomcat-SG
Inbound: SSH TCP 22 from EFE-Project01-Bastion-SG
Outbound: All traffic
```

## RabbitMQ security group

```text
Name: EFE-Project01-RabbitMQ-SG
Inbound: Custom TCP 5672 from EFE-Project01-Tomcat-SG
Inbound: SSH TCP 22 from EFE-Project01-Bastion-SG
Outbound: All traffic
```

## Memcached security group

```text
Name: EFE-Project01-Memcached-SG
Inbound: Custom TCP 11211 from EFE-Project01-Tomcat-SG
Inbound: SSH TCP 22 from EFE-Project01-Bastion-SG
Outbound: All traffic
```

Do not expose ports `3306`, `5672`, `11211`, or `8080` to `0.0.0.0/0`.

---

# Phase 3 — Temporary bastion on RHEL 9

## Find your current public IP

From Windows PowerShell:

```powershell
(Invoke-RestMethod -Uri "https://checkip.amazonaws.com").Trim()
```

Add `/32` when placing the value in the bastion security-group rule.

Example:

```text
154.181.153.186/32
```

## Launch the bastion

```text
Name: EFE-Project01-Bastion
AMI: Official RHEL 9 x86_64
Instance type: t3.micro
Subnet: EFE-Project01-Pub-AZ1
Auto-assign public IPv4: Enabled
Security group: EFE-Project01-Bastion-SG
Key pair: mykey
Storage: 10 GiB gp3
```

## Configure SSH agent forwarding

Run PowerShell as Administrator:

```powershell
Set-Service ssh-agent -StartupType Manual
Start-Service ssh-agent
ssh-add "PATH-TO-YOUR-KEY.pem"
ssh-add -l
```

Connect to the bastion:

```powershell
ssh -A -i "PATH-TO-YOUR-KEY.pem" ec2-user@BASTION_PUBLIC_IP
```

From the bastion, connect to a private backend:

```bash
ssh ec2-user@BACKEND_PRIVATE_IP
```

Do not copy the private key to the bastion.

---

# Phase 4 — Route 53 private DNS

Create a private hosted zone:

```text
Zone: vprofile.internal
Type: Private hosted zone
VPC: EFE-Project01-VPC
Region: eu-north-1
```

After launching the backend instances, create:

| Record | Value |
|---|---|
| `db.vprofile.internal` | MariaDB private IPv4 |
| `mq.vprofile.internal` | RabbitMQ private IPv4 |
| `cache.vprofile.internal` | Memcached private IPv4 |

Verify from any EC2 instance inside the VPC:

```bash
getent hosts db.vprofile.internal
getent hosts mq.vprofile.internal
getent hosts cache.vprofile.internal
```

---

# Phase 5 — MariaDB on RHEL 9

## Launch settings

```text
Name: EFE-Project01-MariaDB
AMI: Official RHEL 9 x86_64
Instance type: t3.micro
Subnet: EFE-Project01-Private-AZ1
Auto-assign public IPv4: Disabled
Security group: EFE-Project01-MariaDB-SG
Key pair: mykey
Storage: 15 GiB gp3
```

Connect through the bastion, then clone the repo and prepare the copied script:

```bash
cp ~/vprofile-original/mariadb.sh ~/vprofile-deployment/mariadb-rhel9.sh
```

<details>
<summary><strong>mariadb-rhel9.sh</strong></summary>

```bash
#!/bin/bash

set -Eeuo pipefail
trap 'echo "ERROR: Script failed at line ${LINENO}." >&2' ERR

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root: sudo bash $0"
    exit 1
fi

DB_NAME="${DB_NAME:-accounts}"
DB_USER="${DB_USER:-admin}"
DB_PASSWORD="${DB_PASSWORD:-admin123}"
SOURCE_REPOSITORY="${SOURCE_REPOSITORY:-https://github.com/abdelrahmanonline4/sourcecodeseniorwr.git}"
SOURCE_BRANCH="${SOURCE_BRANCH:-Master}"
SOURCE_DIRECTORY="${SOURCE_DIRECTORY:-/opt/sourcecodeseniorwr}"
DATABASE_BACKUP="${SOURCE_DIRECTORY}/src/main/resources/db_backup.sql"

echo "Installing Git and MariaDB..."
dnf install -y git mariadb-server

DB_CLIENT="$(command -v mariadb || command -v mysql)"
DB_ADMIN="$(command -v mariadb-admin || command -v mysqladmin)"

echo "Starting and enabling MariaDB..."
systemctl enable --now mariadb

echo "Configuring MariaDB for VPC connections..."
mkdir -p /etc/my.cnf.d
cat > /etc/my.cnf.d/vprofile.cnf <<'MYSQL_CONFIG'
[mysqld]
bind-address=0.0.0.0
MYSQL_CONFIG

systemctl restart mariadb

echo "Waiting for MariaDB..."
for attempt in {1..30}; do
    if "${DB_ADMIN}" -u root ping --silent >/dev/null 2>&1; then
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

echo "Creating the VProfile database and application account..."
"${DB_CLIENT}" -u root <<SQL
DROP DATABASE IF EXISTS test;
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
    CHARACTER SET utf8
    COLLATE utf8_general_ci;

DROP USER IF EXISTS '${DB_USER}'@'%';
CREATE USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

echo "Downloading the application source..."
rm -rf "${SOURCE_DIRECTORY}"
git clone --branch "${SOURCE_BRANCH}" --single-branch "${SOURCE_REPOSITORY}" "${SOURCE_DIRECTORY}"

if [[ ! -f "${DATABASE_BACKUP}" ]]; then
    echo "Database backup not found: ${DATABASE_BACKUP}"
    exit 1
fi

echo "Importing the database backup..."
"${DB_CLIENT}" -u root "${DB_NAME}" < "${DATABASE_BACKUP}"

echo "Configuring firewalld when active..."
if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port=3306/tcp
    firewall-cmd --reload
else
    echo "Firewalld is inactive; AWS Security Groups control TCP port 3306."
fi

echo "Restarting MariaDB..."
systemctl restart mariadb

echo "Verifying tables and imported data..."
"${DB_CLIENT}" -u root -e "USE ${DB_NAME}; SHOW TABLES; SELECT COUNT(*) AS users FROM user;"

echo "Testing application credentials through TCP..."
"${DB_CLIENT}" --host=127.0.0.1 --user="${DB_USER}" --password="${DB_PASSWORD}" --execute="USE ${DB_NAME}; SELECT COUNT(*) AS users FROM user;"

echo "Checking TCP port 3306..."
ss -lntp | grep ':3306'

echo "MariaDB deployment completed successfully."
echo "Database: ${DB_NAME}"
echo "Application user: ${DB_USER}"
echo "Port: 3306"
```

</details>

Run it:

```bash
chmod +x ~/vprofile-deployment/mariadb-rhel9.sh
bash -n ~/vprofile-deployment/mariadb-rhel9.sh
sudo bash ~/vprofile-deployment/mariadb-rhel9.sh
```

Expected tables:

```text
role
user
user_role
```

Expected user count:

```text
10
```

Create the Route 53 record:

```text
db.vprofile.internal -> MariaDB private IPv4
```

Verify:

```bash
mysql --host=db.vprofile.internal --user=admin --password=admin123 --execute="USE accounts; SELECT COUNT(*) AS users FROM user;" 2>/dev/null \
|| mariadb --host=db.vprofile.internal --user=admin --password=admin123 --execute="USE accounts; SELECT COUNT(*) AS users FROM user;"
```

---

# Phase 6 — RabbitMQ on RHEL 9

## Launch settings

```text
Name: EFE-Project01-RabbitMQ
AMI: Official RHEL 9 x86_64
Instance type: t3.micro
Subnet: EFE-Project01-Private-AZ2
Auto-assign public IPv4: Disabled
Security group: EFE-Project01-RabbitMQ-SG
Key pair: mykey
Storage: 10 GiB gp3
```

Connect through the bastion, then clone the repo and prepare the copied script:

```bash
cp ~/vprofile-original/rabbitmq.sh ~/vprofile-deployment/rabbitmq-rhel9.sh
```

<details>
<summary><strong>rabbitmq-rhel9.sh</strong></summary>

```bash
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
```

</details>

Run it:

```bash
chmod +x ~/vprofile-deployment/rabbitmq-rhel9.sh
bash -n ~/vprofile-deployment/rabbitmq-rhel9.sh
sudo RABBITMQ_PASSWORD='test' \
bash ~/vprofile-deployment/rabbitmq-rhel9.sh
```

Create the Route 53 record:

```text
mq.vprofile.internal -> RabbitMQ private IPv4
```

Verify:

```bash
sudo rabbitmqctl authenticate_user test test
sudo rabbitmq-diagnostics listeners
getent hosts mq.vprofile.internal
timeout 3 bash -c '</dev/tcp/mq.vprofile.internal/5672' && echo reachable
```

---

# Phase 7 — Memcached on RHEL 9

## Launch settings

```text
Name: EFE-Project01-Memcached
AMI: Official RHEL 9 x86_64
Instance type: t3.micro
Subnet: EFE-Project01-Private-AZ1
Auto-assign public IPv4: Disabled
Security group: EFE-Project01-Memcached-SG
Key pair: mykey
Storage: 10 GiB gp3
```

Connect through the bastion, then clone the repo and prepare the copied script:

```bash
cp ~/vprofile-original/memcached.sh ~/vprofile-deployment/memcached-rhel9.sh
```

<details>
<summary><strong>memcached-rhel9.sh</strong></summary>

```bash
#!/bin/bash

set -Eeuo pipefail
trap 'echo "ERROR: Script failed at line ${LINENO}." >&2' ERR

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root: sudo bash $0"
    exit 1
fi

MEMCACHED_PORT="${MEMCACHED_PORT:-11211}"
MEMCACHED_USER="${MEMCACHED_USER:-memcached}"
MEMCACHED_MEMORY_MB="${MEMCACHED_MEMORY_MB:-64}"
MEMCACHED_MAX_CONNECTIONS="${MEMCACHED_MAX_CONNECTIONS:-1024}"

echo "Installing Memcached..."
dnf install -y memcached

echo "Configuring Memcached..."
cat > /etc/sysconfig/memcached <<MEMCACHED_CONFIG
PORT="${MEMCACHED_PORT}"
USER="${MEMCACHED_USER}"
MAXCONN="${MEMCACHED_MAX_CONNECTIONS}"
CACHESIZE="${MEMCACHED_MEMORY_MB}"
OPTIONS="-l 0.0.0.0 -U 0"
MEMCACHED_CONFIG

echo "Starting and enabling Memcached..."
systemctl enable --now memcached
systemctl restart memcached

echo "Waiting for Memcached..."
for attempt in {1..20}; do
    if ss -lnt | grep -q ":${MEMCACHED_PORT}"; then
        break
    fi

    if [[ "${attempt}" -eq 20 ]]; then
        echo "Memcached did not start successfully."
        systemctl --no-pager --full status memcached || true
        journalctl -u memcached --no-pager -n 100 || true
        exit 1
    fi

    sleep 1
done

echo "Configuring firewalld when active..."
if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${MEMCACHED_PORT}"/tcp
    firewall-cmd --reload
else
    echo "Firewalld is inactive; AWS Security Groups control TCP port ${MEMCACHED_PORT}."
fi

echo "Testing Memcached..."
MEMCACHED_RESPONSE="$(timeout 5 bash -c '
exec 3<>/dev/tcp/127.0.0.1/11211
printf "version\r\n" >&3
IFS= read -r response <&3
printf "%s" "${response}"
')"

echo "Memcached response: ${MEMCACHED_RESPONSE}"

if [[ "${MEMCACHED_RESPONSE}" != VERSION* ]]; then
    echo "Memcached did not return a valid VERSION response."
    exit 1
fi

if ss -lunp | grep -q ":${MEMCACHED_PORT}"; then
    echo "UDP is unexpectedly enabled on port ${MEMCACHED_PORT}."
    exit 1
fi

echo "Verifying the service and listener..."
systemctl --no-pager --full status memcached
ss -lntp | grep ":${MEMCACHED_PORT}"

echo "Memcached deployment completed successfully."
echo "TCP port: ${MEMCACHED_PORT}"
echo "UDP: disabled"
```

</details>

Run it:

```bash
chmod +x ~/vprofile-deployment/memcached-rhel9.sh
bash -n ~/vprofile-deployment/memcached-rhel9.sh
sudo bash ~/vprofile-deployment/memcached-rhel9.sh
```

Create the Route 53 record:

```text
cache.vprofile.internal -> Memcached private IPv4
```

Verify:

```bash
timeout 5 bash -c '
exec 3<>/dev/tcp/cache.vprofile.internal/11211
printf "version\r\n" >&3
IFS= read -r response <&3
printf "%s\n" "$response"
'
```

Expected:

```text
VERSION 1.6.x
```

---

# Phase 8 — Terminate the bastion and update SSH access

Do this only after MariaDB, RabbitMQ, Memcached, and Route 53 DNS have been verified.

## 1. Record the backend private IPs

Save the private IP addresses of:

```text
EFE-Project01-MariaDB
EFE-Project01-RabbitMQ
EFE-Project01-Memcached
```

## 2. Terminate the bastion

In the EC2 console:

```text
Instances -> EFE-Project01-Bastion -> Instance state -> Terminate instance
```

Wait until the instance is terminated and the vCPU quota is released.

## 3. Update the Tomcat security group

Add:

```text
SSH TCP 22 from YOUR_PUBLIC_IP/32
```

Keep:

```text
Custom TCP 8080 from EFE-Project01-ALB-SG
```

Do not expose `8080` to the internet.

## 4. Update backend security groups

For each backend security group:

```text
EFE-Project01-MariaDB-SG
EFE-Project01-RabbitMQ-SG
EFE-Project01-Memcached-SG
```

Remove:

```text
SSH TCP 22 from EFE-Project01-Bastion-SG
```

Add:

```text
SSH TCP 22 from EFE-Project01-Tomcat-SG
```

This lets the Tomcat instance act as the temporary jump host after it is launched.

The service rules remain unchanged:

```text
MariaDB 3306 from EFE-Project01-Tomcat-SG
RabbitMQ 5672 from EFE-Project01-Tomcat-SG
Memcached 11211 from EFE-Project01-Tomcat-SG
```

The unused bastion security group can be deleted after all references to it are removed.

---

# Phase 9 — Tomcat and VProfile on RHEL 9

## Launch settings

```text
Name: EFE-Project01-Tomcat
AMI: Official RHEL 9 x86_64
Instance type: t3.micro
Subnet: EFE-Project01-Pub-AZ1
Auto-assign public IPv4: Enabled
Security group: EFE-Project01-Tomcat-SG
Key pair: mykey
Storage: 15 GiB gp3
```

The public IPv4 address is used only for SSH administration. Application traffic still enters through the ALB.

If the instance is stopped and started, its public IPv4 may change. Allocate an Elastic IP only if a stable administrative address is required.

## Connect directly from Windows

```powershell
ssh -A -i "C:\Users\Mohamed Ali\mykey.pem" ec2-user@TOMCAT_PUBLIC_IP
```

The `-A` option is needed when using Tomcat as a jump host to the backend servers.

From Tomcat, access a backend:

```bash
ssh ec2-user@BACKEND_PRIVATE_IP
```

## Prepare the copied script

```bash
sudo dnf install -y git
cd ~
git clone -b Master https://github.com/abdelrahmanonline4/vprofile-test.git vprofile-original
mkdir -p ~/vprofile-deployment
cp ~/vprofile-original/tomcat.sh ~/vprofile-deployment/tomcat-rhel9.sh
```

<details>
<summary><strong>tomcat-rhel9.sh</strong></summary>

```bash
#!/bin/bash

set -Eeuo pipefail
trap 'echo "ERROR: Script failed at line ${LINENO}." >&2' ERR

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root: sudo bash $0"
    exit 1
fi

TOMCAT_VERSION="${TOMCAT_VERSION:-9.0.120}"
TOMCAT_HOME="${TOMCAT_HOME:-/usr/local/tomcat}"
TOMCAT_ARCHIVE="apache-tomcat-${TOMCAT_VERSION}.tar.gz"
TOMCAT_URL="https://dlcdn.apache.org/tomcat/tomcat-9/v${TOMCAT_VERSION}/bin/${TOMCAT_ARCHIVE}"

SOURCE_REPOSITORY="${SOURCE_REPOSITORY:-https://github.com/abdelrahmanonline4/sourcecodeseniorwr.git}"
SOURCE_BRANCH="${SOURCE_BRANCH:-Master}"
SOURCE_DIRECTORY="${SOURCE_DIRECTORY:-/opt/vprofile-source}"
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

echo "Creating a 2 GiB swap file when no swap exists..."
if [[ -z "$(swapon --show --noheadings)" ]]; then
    if ! fallocate -l 2G /swapfile; then
        dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
    fi

    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    if ! grep -q '^/swapfile ' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
fi

free -h

echo "Installing Java 17, Maven, Git, and tools..."
dnf install -y java-17-openjdk-devel git maven curl tar

JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
export JAVA_HOME
export PATH="${JAVA_HOME}/bin:${PATH}"

echo "JAVA_HOME=${JAVA_HOME}"
java -version
javac -version
mvn -version

echo "Checking private DNS..."
getent hosts "${DB_HOST}"
getent hosts "${CACHE_HOST}"
getent hosts "${RABBITMQ_HOST}"

check_port() {
    local host="$1"
    local port="$2"
    local service="$3"

    echo "Checking ${service}: ${host}:${port}"

    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}"; then
        echo "${service} is reachable."
    else
        echo "${service} is not reachable."
        exit 1
    fi
}

echo "Checking backend connectivity..."
check_port "${DB_HOST}" "${DB_PORT}" "MariaDB"

if [[ "${SKIP_MEMCACHED_CHECK}" == "true" ]]; then
    echo "Skipping Memcached connectivity check."
else
    check_port "${CACHE_HOST}" "${CACHE_PORT}" "Memcached"
fi

check_port "${RABBITMQ_HOST}" "${RABBITMQ_PORT}" "RabbitMQ"

echo "Downloading Apache Tomcat ${TOMCAT_VERSION}..."
cd /tmp
rm -f "${TOMCAT_ARCHIVE}" "${TOMCAT_ARCHIVE}.sha512"
curl --fail --location "${TOMCAT_URL}" --output "${TOMCAT_ARCHIVE}"
curl --fail --location "${TOMCAT_URL}.sha512" --output "${TOMCAT_ARCHIVE}.sha512"
sha512sum --check "${TOMCAT_ARCHIVE}.sha512"

echo "Creating the Tomcat service account..."
if ! id tomcat >/dev/null 2>&1; then
    useradd --system --home-dir "${TOMCAT_HOME}" --shell /sbin/nologin tomcat
fi

echo "Installing Tomcat..."
systemctl stop tomcat >/dev/null 2>&1 || true
rm -rf "${TOMCAT_HOME}"
mkdir -p "${TOMCAT_HOME}"
tar --extract --gzip --file="/tmp/${TOMCAT_ARCHIVE}" --directory="${TOMCAT_HOME}" --strip-components=1
chmod +x "${TOMCAT_HOME}/bin/"*.sh
chown -R tomcat:tomcat "${TOMCAT_HOME}"

echo "Creating the Tomcat systemd service..."
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
Environment="CATALINA_OPTS=-Xms128M -Xmx384M -server -XX:+UseParallelGC"
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

echo "Downloading the application source..."
rm -rf "${SOURCE_DIRECTORY}"
git clone --branch "${SOURCE_BRANCH}" --single-branch "${SOURCE_REPOSITORY}" "${SOURCE_DIRECTORY}"

if [[ ! -f "${APPLICATION_PROPERTIES}" ]]; then
    echo "application.properties was not found: ${APPLICATION_PROPERTIES}"
    exit 1
fi

echo "Writing the AWS application configuration..."
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

# Elasticsearch configuration - intentionally skipped in this lab
elasticsearch.host=search.vprofile.internal
elasticsearch.port=9300
elasticsearch.cluster=vprofile
elasticsearch.node=vprofilenode
APP_PROPERTIES

echo "Building the WAR file..."
cd "${SOURCE_DIRECTORY}"
MAVEN_OPTS="-Xms128m -Xmx512m" mvn --batch-mode clean package -DskipTests

if [[ ! -f "${WAR_FILE}" ]]; then
    echo "WAR file was not generated: ${WAR_FILE}"
    exit 1
fi

ls -lh "${WAR_FILE}"

echo "Deploying VProfile..."
rm -rf "${TOMCAT_HOME}/webapps/"*
install -o tomcat -g tomcat -m 0644 "${WAR_FILE}" "${TOMCAT_HOME}/webapps/ROOT.war"
chown -R tomcat:tomcat "${TOMCAT_HOME}"

echo "Configuring firewalld when active..."
if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port=8080/tcp
    firewall-cmd --reload
else
    echo "Firewalld is inactive; AWS Security Groups control TCP port 8080."
fi

echo "Starting Tomcat..."
systemctl enable --now tomcat

echo "Waiting for the application login page..."
APPLICATION_READY="false"

for attempt in {1..60}; do
    HTTP_STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' http://127.0.0.1:8080/login || true)"

    if [[ "${HTTP_STATUS}" == "200" ]]; then
        APPLICATION_READY="true"
        break
    fi

    echo "Attempt ${attempt}/60: application returned HTTP ${HTTP_STATUS}"
    sleep 2
done

if [[ "${APPLICATION_READY}" != "true" ]]; then
    echo "The application did not become ready."
    systemctl --no-pager --full status tomcat || true
    journalctl --unit=tomcat --no-pager --lines=150 || true
    exit 1
fi

echo "Verifying Tomcat and VProfile..."
systemctl --no-pager --full status tomcat
ss -lntp | grep ':8080'

LOGIN_STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' http://127.0.0.1:8080/login)"
ROOT_STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' http://127.0.0.1:8080/)"

echo "Login page HTTP status: ${LOGIN_STATUS}"
echo "Root path HTTP status: ${ROOT_STATUS}"

if [[ "${LOGIN_STATUS}" != "200" ]]; then
    echo "The login page is not healthy."
    exit 1
fi

if [[ "${ROOT_STATUS}" != "302" && "${ROOT_STATUS}" != "200" ]]; then
    echo "The application root returned an unexpected status."
    exit 1
fi

echo "Tomcat deployment completed successfully."
echo "Tomcat version: ${TOMCAT_VERSION}"
echo "Application port: 8080"
```

</details>

Run it:

```bash
chmod +x ~/vprofile-deployment/tomcat-rhel9.sh
bash -n ~/vprofile-deployment/tomcat-rhel9.sh
sudo bash ~/vprofile-deployment/tomcat-rhel9.sh
```

If Memcached is intentionally stopped during troubleshooting:

```bash
sudo SKIP_MEMCACHED_CHECK=true bash ~/vprofile-deployment/tomcat-rhel9.sh
```

Verify locally:

```bash
sudo systemctl status tomcat --no-pager
sudo ss -lntp | grep 8080
curl -sS -o /dev/null -w "HTTP status: %{http_code}\n" http://127.0.0.1:8080/login
curl -sS -o /dev/null -w "HTTP status: %{http_code}\n" http://127.0.0.1:8080/
```

Expected:

```text
/login -> 200
/      -> 302 or 200
```

---

# Phase 10 — Target group

Create an instance target group:

```text
Name: EFE-Project01-Tomcat-TG
Target type: Instances
Protocol: HTTP
Port: 8080
VPC: EFE-Project01-VPC
Protocol version: HTTP1
```

Health check:

```text
Protocol: HTTP
Port: Traffic port
Path: /login
Success code: 200
Healthy threshold: 2
Unhealthy threshold: 2
Timeout: 5 seconds
Interval: 30 seconds
```

Register `EFE-Project01-Tomcat` on port `8080`.

The ALB reaches the instance through its **private IP**, even though the Tomcat instance also has a public IPv4 address.

---

# Phase 11 — Application Load Balancer

Create an Application Load Balancer:

```text
Name: EFE-Project01-ALB
Scheme: Internet-facing
IP address type: IPv4
VPC: EFE-Project01-VPC
Subnets: EFE-Project01-Pub-AZ1 and EFE-Project01-Pub-AZ2
Security group: EFE-Project01-ALB-SG
```

Listener:

```text
Protocol: HTTP
Port: 80
Default action: Forward to EFE-Project01-Tomcat-TG
```

Verify:

```text
Load balancer state: Active
Target group association: EFE-Project01-ALB
Target status: Healthy
```

Test from Windows PowerShell:

```powershell
Test-NetConnection ALB_DNS_NAME -Port 80
curl.exe -v http://ALB_DNS_NAME/
curl.exe -o NUL -s -w "HTTP status: %{http_code}`n" http://ALB_DNS_NAME/login
```

Expected:

```text
TcpTestSucceeded : True
GET /login       : 200
GET /            : 302 to /login, or 200
```

---

# Final SSH workflow after bastion deletion

Connect directly to Tomcat:

```powershell
ssh -A -i "C:\Users\Mohamed Ali\mykey.pem" ec2-user@TOMCAT_PUBLIC_IP
```

From Tomcat, connect to MariaDB:

```bash
ssh ec2-user@MARIADB_PRIVATE_IP
```

From Tomcat, connect to RabbitMQ:

```bash
ssh ec2-user@RABBITMQ_PRIVATE_IP
```

From Tomcat, connect to Memcached:

```bash
ssh ec2-user@MEMCACHED_PRIVATE_IP
```

Confirm that the backend security groups allow SSH from `EFE-Project01-Tomcat-SG`.

---

# Troubleshooting and solutions

## 1. EC2 launch failed because of the 8-vCPU quota

### Error

```text
You have requested more vCPU capacity than your current vCPU limit of 8 allows.
```

### Cause

Each T3 instance in this project consumes two vCPUs. The temporary bastion plus three backend servers already consume eight vCPUs.

### Solution

1. Finish backend configuration through the bastion.
2. Terminate the bastion.
3. Wait for the quota to be released.
4. Launch the Tomcat instance.

Changing `t3.small` to `t3.micro` does not reduce vCPU consumption because both use two vCPUs.

---

## 2. Private backend SSH stopped working after bastion deletion

### Cause

The backend security groups still allowed SSH only from `EFE-Project01-Bastion-SG`.

### Solution

Replace the SSH source in each backend security group:

```text
Remove: TCP 22 from EFE-Project01-Bastion-SG
Add:    TCP 22 from EFE-Project01-Tomcat-SG
```

Connect to Tomcat with agent forwarding, then connect to the private backend.

---

## 3. Tomcat public IP changed

### Cause

An automatically assigned public IPv4 normally changes after an instance stop/start cycle.

### Solution

- Copy the new public IP from the EC2 console and update the SSH command.
- Optionally associate an Elastic IP if a stable address is required.
- Update the `YOUR_PUBLIC_IP/32` SSH rule only when the administrator's public IP changes, not when the EC2 public IP changes.

---




## 5. `mariadb` or `mysql` command was not found

RHEL package versions may expose either client name.

Use automatic detection:

```bash
DB_CLIENT="$(command -v mariadb || command -v mysql)"
"${DB_CLIENT}" -u root -e "SELECT VERSION();"
```

The corrected MariaDB script already does this.

---

## 6. MariaDB credentials did not match the application

### Original conflict

The original application properties and original MariaDB script used different credentials.

### Solution

Both corrected scripts use:

```properties
jdbc.username=admin
jdbc.password=admin123
```

---

## 7. RabbitMQ user had no virtual-host permissions

Creating an administrator user does not automatically grant queue and exchange permissions.

Use:

```bash
rabbitmqctl set_permissions -p / test '.*' '.*' '.*'
```

The corrected script also deletes the remote-incompatible default `guest` account.

---

## 8. Memcached started twice

### Original problem

The original script started the systemd service and then launched another daemon manually.

It also contained an invalid line containing only `1` and opened an unnecessary UDP port.

### Solution

Use only systemd and disable UDP:

```text
OPTIONS="-l 0.0.0.0 -U 0"
```

Only TCP `11211` is permitted from the Tomcat security group.

---

## 9. Tomcat deployment failed with `No route to host` for Memcached

### Cause

The Memcached instance was stopped, its security group was wrong, or the Route 53 record pointed to an old private IP.

### Checks

```bash
getent hosts cache.vprofile.internal
timeout 5 bash -c '</dev/tcp/cache.vprofile.internal/11211'
```

### Temporary workaround

```bash
sudo SKIP_MEMCACHED_CHECK=true bash ~/vprofile-deployment/tomcat-rhel9.sh
```

This permits deployment but does not make cache-dependent behavior healthy.

---

## 10. Tomcat service did not exist after a failed script

### Cause

`set -Eeuo pipefail` stopped the script during backend checks before the Tomcat service was created.

### Solution

Fix the failed DNS, security-group, or service connection, then rerun the full script.

---

## 11. `/instance.txt` returned 404

### Cause

The application has no Spring mapping for `/instance.txt`.

### Solution

Use `/login` for readiness and ALB health checks:

```bash
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/login
```

Expected:

```text
200
```

---

## 12. `curl -I /login` returned 405

### Cause

`curl -I` sends a `HEAD` request, while `/login` accepts `GET`.

### Solution

Use a normal GET request:

```bash
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/login
```

The ALB health check uses GET, so `/login` is valid.

---

## 13. `break` was reported as invalid

### Error

```text
break: only meaningful in a for, while, or until loop
```

### Cause

A fragment containing `break` was pasted directly into the shell outside its loop.

### Solution

Test directly:

```bash
HTTP_STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' http://127.0.0.1:8080/login)"
echo "${HTTP_STATUS}"
```

---

## 14. Browser timed out while the target group showed healthy

### Observed state

- Port 80 was reachable.
- The Tomcat target was healthy.
- The target group showed `Load balancer: None associated`.

### Cause

The ALB listener was not forwarding to the target group.

### Solution

Configure:

```text
HTTP : 80
Default action -> Forward to EFE-Project01-Tomcat-TG
```

Then confirm the target group shows `EFE-Project01-ALB` as associated.

---

## 15. SSH agent forwarding failed

### Common causes

- Lowercase `-j` was used instead of uppercase `-J`.
- The local key was not loaded into the SSH agent.
- The first connection did not include `-A`.

### Solution

```powershell
ssh-add "C:\Users\Mohamed Ali\mykey.pem"
ssh -A -i "C:\Users\Mohamed Ali\mykey.pem" ec2-user@TOMCAT_PUBLIC_IP
```

Then:

```bash
ssh ec2-user@BACKEND_PRIVATE_IP
```

---

## 16. Tomcat was reachable directly on port 8080 from the internet

### Cause

The Tomcat security group allowed `0.0.0.0/0` on port `8080`.

### Solution

Remove the public rule and use:

```text
TCP 8080 from EFE-Project01-ALB-SG only
```

The public IP is for SSH administration, not direct application access.

---

## 17. Elasticsearch was skipped

The application configuration still contains:

```properties
elasticsearch.host=search.vprofile.internal
elasticsearch.port=9300
elasticsearch.cluster=vprofile
elasticsearch.node=vprofilenode
```

Normal login and application startup can work, but search-related functionality may fail.

---

# Final verification checklist

## MariaDB

```bash
mysql --host=db.vprofile.internal --user=admin --password=admin123 --execute="USE accounts; SELECT COUNT(*) AS users FROM user;" 2>/dev/null \
|| mariadb --host=db.vprofile.internal --user=admin --password=admin123 --execute="USE accounts; SELECT COUNT(*) AS users FROM user;"
```

Expected user count: `10`.

## RabbitMQ

```bash
sudo rabbitmqctl authenticate_user test test
sudo rabbitmq-diagnostics listeners
```

Expected listener: TCP `5672`.

## Memcached

```bash
timeout 5 bash -c '
exec 3<>/dev/tcp/cache.vprofile.internal/11211
printf "version\r\n" >&3
IFS= read -r response <&3
printf "%s\n" "$response"
'
```

Expected: `VERSION ...`.

## Tomcat

```bash
sudo systemctl is-active tomcat
sudo ss -lntp | grep 8080
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/login
```

Expected:

```text
active
LISTEN on 8080
200
```

## Target group

```text
Target: Healthy
Health path: /login
Success code: 200
Load balancer: EFE-Project01-ALB
```

## ALB

```powershell
Test-NetConnection ALB_DNS_NAME -Port 80
curl.exe -o NUL -s -w "HTTP status: %{http_code}`n" http://ALB_DNS_NAME/login
```

Expected:

```text
TcpTestSucceeded : True
HTTP status: 200
```

## Backend SSH through Tomcat

```powershell
ssh -A -i "C:\Users\Mohamed Ali\mykey.pem" ec2-user@TOMCAT_PUBLIC_IP
```

Then:

```bash
ssh ec2-user@MARIADB_PRIVATE_IP
```

---

# Security and production notes

This design is appropriate for a constrained lab, not production.

Production improvements:

- Keep Tomcat in private subnets.
- Use AWS Systems Manager Session Manager instead of public SSH.
- Deploy at least two Tomcat instances across two AZs.
- Add Auto Scaling.
- Replace MariaDB EC2 with Amazon RDS Multi-AZ.
- Replace Memcached EC2 with Amazon ElastiCache.
- Replace RabbitMQ EC2 with Amazon MQ where appropriate.
- Deploy a compatible Elasticsearch/OpenSearch solution.
- Store credentials in AWS Secrets Manager or SSM Parameter Store.
- Add HTTPS with AWS Certificate Manager.
- Add CloudWatch logs, metrics, and alarms.
- Build the WAR once in CI/CD and deploy the same artifact to every application server.
- Convert the infrastructure to Terraform.

---

# Cleanup

To avoid unnecessary cost:

1. Delete the Application Load Balancer.
2. Delete the target group.
3. Terminate all EC2 instances.
4. Delete NAT Gateways.
5. Release their Elastic IPs.
6. Delete Route 53 private hosted-zone records and the zone.
7. Delete security groups after dependencies are removed.
8. Delete route tables, subnets, Internet Gateway, and VPC.


