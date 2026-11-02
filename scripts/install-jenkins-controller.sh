#!/bin/bash
# Runs as EC2 user_data (root) on Ubuntu 22.04. Jenkins controller only: it never builds anything.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y ca-certificates curl gnupg fontconfig openjdk-17-jre

install -d -m 0755 /etc/apt/keyrings
# The Jenkins repo signing key rotates yearly. If this URL 404s, copy the current one from https://pkg.jenkins.io/debian-stable/
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key -o /etc/apt/keyrings/jenkins-keyring.asc
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  > /etc/apt/sources.list.d/jenkins.list

apt-get update -y
apt-get install -y jenkins
systemctl enable --now jenkins
