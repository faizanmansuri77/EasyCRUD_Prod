#!/bin/bash
# Runs as EC2 user_data (root) on Ubuntu 22.04. SonarQube Community + PostgreSQL in Docker.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y docker.io openssl
systemctl enable --now docker

# Required by SonarQube's embedded Elasticsearch
cat > /etc/sysctl.d/99-sonarqube.conf <<'SYS'
vm.max_map_count=524288
fs.file-max=131072
SYS
sysctl --system

install -d -m 0700 /opt/sonarqube
if [ ! -f /opt/sonarqube/db.env ]; then
  umask 077
  echo "DB_PASSWORD=$(openssl rand -hex 24)" > /opt/sonarqube/db.env
fi
# shellcheck disable=SC1091
. /opt/sonarqube/db.env

docker network inspect sonar >/dev/null 2>&1 || docker network create sonar

docker run -d --name sonar-db --network sonar --restart unless-stopped \
  -e POSTGRES_USER=sonar -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=sonarqube \
  -v sonar_pgdata:/var/lib/postgresql/data \
  postgres:16-alpine

docker run -d --name sonarqube --network sonar --restart unless-stopped \
  -p 9000:9000 \
  -e SONAR_JDBC_URL=jdbc:postgresql://sonar-db:5432/sonarqube \
  -e SONAR_JDBC_USERNAME=sonar -e SONAR_JDBC_PASSWORD="$DB_PASSWORD" \
  -v sonar_data:/opt/sonarqube/data \
  -v sonar_extensions:/opt/sonarqube/extensions \
  -v sonar_logs:/opt/sonarqube/logs \
  sonarqube:community
