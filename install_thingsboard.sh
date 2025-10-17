#!/usr/bin/env bash
set -euo pipefail

# Check if input config file is provided
if [ $# -lt 1 ]; then
  echo "Usage: $0 <config-file>"
  exit 1
fi

# Load configuration
source "$1"

# ========== Begin Installation ==========

echo "Updating apt and installing prerequisites..."
sudo apt update
sudo apt install -y wget gnupg curl apt-transport-https

echo "Installing Java ($JAVA_VERSION)..."
sudo apt install -y "$JAVA_VERSION"

echo "Ensuring Java is available..."
java -version || { echo "Java installation failed!"; exit 1; }

echo "Downloading ThingsBoard v${TB_VERSION}..."
wget "https://github.com/thingsboard/thingsboard/releases/download/v${TB_VERSION}/thingsboard-${TB_VERSION}.deb"

echo "Installing ThingsBoard..."
sudo dpkg -i "thingsboard-${TB_VERSION}.deb"

echo "Installing PostgreSQL..."
sudo apt install -y postgresql-common
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh
sudo apt update
sudo apt -y install postgresql-17
sudo systemctl enable postgresql
sudo systemctl start postgresql

echo "Setting PostgreSQL password..."
sudo -u postgres psql -c "ALTER USER ${PG_USER} WITH PASSWORD '${PG_PASSWORD}';"

echo "Creating database ${PG_DB}..."
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${PG_DB}'" | grep -q 1 || \
sudo -u postgres psql -c "CREATE DATABASE ${PG_DB};"

echo "Configuring ThingsBoard PostgreSQL connection..."
sudo cp /etc/thingsboard/conf/thingsboard.conf /etc/thingsboard/conf/thingsboard.conf.bak || true

sudo tee -a /etc/thingsboard/conf/thingsboard.conf > /dev/null <<EOF
# PostgreSQL config
export DATABASE_TS_TYPE=sql
export SPRING_DATASOURCE_URL=jdbc:postgresql://localhost:5432/${PG_DB}
export SPRING_DATASOURCE_USERNAME=${PG_USER}
export SPRING_DATASOURCE_PASSWORD=${PG_PASSWORD}
export SQL_POSTGRES_TS_KV_PARTITIONING=MONTHS
EOF

echo "Checking Docker..."
if ! command -v docker &>/dev/null; then
  echo "Installing Docker..."
  sudo apt install -y docker.io
  sudo systemctl enable docker
  sudo systemctl start docker
fi

if ! command -v docker-compose &>/dev/null; then
  echo "Installing Docker Compose..."
  sudo apt install -y docker-compose
fi

echo "Creating Docker Compose file for Kafka..."
cat > "${DOCKER_COMPOSE_FILE}" <<EOF
version: '3.8'
services:
  kafka:
    restart: always
    image: ${KAFKA_IMAGE}
    ports:
      - 9092:9092
      - 9093
      - 9094
    environment:
      ALLOW_PLAINTEXT_LISTENER: "yes"
      KAFKA_CFG_LISTENERS: "OUTSIDE://:9092,CONTROLLER://:9093,INSIDE://:9094"
      KAFKA_CFG_ADVERTISED_LISTENERS: "OUTSIDE://localhost:9092,INSIDE://kafka:9094"
      KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP: "INSIDE:PLAINTEXT,OUTSIDE:PLAINTEXT,CONTROLLER:PLAINTEXT"
      KAFKA_CFG_INTER_BROKER_LISTENER_NAME: "INSIDE"
      KAFKA_CFG_AUTO_CREATE_TOPICS_ENABLE: "false"
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: "1"
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: "1"
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: "1"
      KAFKA_CFG_PROCESS_ROLES: "controller,broker"
      KAFKA_CFG_NODE_ID: "0"
      KAFKA_CFG_CONTROLLER_LISTENER_NAMES: "CONTROLLER"
      KAFKA_CFG_CONTROLLER_QUORUM_VOTERS: "0@kafka:9093"
    volumes:
      - kafka-data:/bitnami
volumes:
  kafka-data:
    driver: local
EOF

echo "Starting Kafka container..."
docker-compose -f "${DOCKER_COMPOSE_FILE}" up -d

echo "Configuring ThingsBoard Kafka queue..."
sudo tee -a /etc/thingsboard/conf/thingsboard.conf > /dev/null <<EOF
export TB_QUEUE_TYPE=kafka
export TB_KAFKA_SERVERS=localhost:9092

# Memory tuning
export JAVA_OPTS="\$JAVA_OPTS -Xms${JAVA_XMS} -Xmx${JAVA_XMX}"
EOF

echo "Running ThingsBoard installation (with demo data)..."
sudo /usr/share/thingsboard/bin/install/install.sh --installDir=/usr/share/thingsboard --loadDemo

echo "Starting ThingsBoard service..."
sudo systemctl enable thingsboard
sudo service thingsboard start

echo "Installation complete!"
echo "Access at: http://<your_vm_ip>:8080"
