#!/bin/bash
# Runs as EC2 user_data (root) on Ubuntu 22.04. Build agent: Docker, Maven, scanners, kubectl, AWS CLI.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

KUBECTL_MINOR="1.34"        # keep within one minor version of the EKS cluster_version
GITLEAKS_VERSION="8.28.0"   # bump when needed: https://github.com/gitleaks/gitleaks/releases

apt-get update -y
apt-get install -y ca-certificates curl gnupg git unzip jq gettext-base wget \
  openjdk-17-jdk maven docker.io

systemctl enable --now docker

# Dedicated, unprivileged-by-default user for the agent process
useradd -m -s /bin/bash jenkins-agent || true
usermod -aG docker jenkins-agent    # docker group is root-equivalent: this host only runs trusted pipelines

# AWS CLI v2
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install --update
rm -rf /tmp/aws /tmp/awscliv2.zip

# kubectl (latest patch of the matching minor)
KUBECTL_VERSION="$(curl -fsSL "https://dl.k8s.io/release/stable-${KUBECTL_MINOR}.txt")"
curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
chmod 0755 /usr/local/bin/kubectl

# Trivy (dependency, image and config scanning)
curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor -o /usr/share/keyrings/trivy.gpg
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
  > /etc/apt/sources.list.d/trivy.list
apt-get update -y && apt-get install -y trivy

# Gitleaks (secret scanning)
curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
  | tar -xz -C /usr/local/bin gitleaks

# --- Jenkins inbound (WebSocket) agent as a systemd service -----------------------------------
install -d -o jenkins-agent -g jenkins-agent /opt/jenkins-agent /home/jenkins-agent
install -d -m 0750 -o root -g jenkins-agent /etc/jenkins-agent

cat > /etc/systemd/system/jenkins-agent.service <<'UNIT'
[Unit]
Description=Jenkins inbound agent
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=jenkins-agent
EnvironmentFile=/etc/jenkins-agent/agent.env
ExecStart=/usr/bin/java -jar /opt/jenkins-agent/agent.jar -url ${JENKINS_URL} -secret ${JENKINS_SECRET} -name ${JENKINS_AGENT_NAME} -webSocket -workDir /home/jenkins-agent
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

# Helper you run ONCE after creating the node in the Jenkins UI:
#   sudo setup-jenkins-agent http://<controller-private-ip>:8080 <secret> build-agent-1
cat > /usr/local/bin/setup-jenkins-agent <<'HELPER'
#!/bin/bash
set -euo pipefail
URL="${1:?jenkins url}"; SECRET="${2:?agent secret}"; NAME="${3:-build-agent-1}"
curl -fsSL "$URL/jnlpJars/agent.jar" -o /opt/jenkins-agent/agent.jar
chown jenkins-agent:jenkins-agent /opt/jenkins-agent/agent.jar
umask 077
printf 'JENKINS_URL=%s\nJENKINS_SECRET=%s\nJENKINS_AGENT_NAME=%s\n' "$URL" "$SECRET" "$NAME" > /etc/jenkins-agent/agent.env
chown root:jenkins-agent /etc/jenkins-agent/agent.env && chmod 0640 /etc/jenkins-agent/agent.env
systemctl daemon-reload
systemctl enable --now jenkins-agent
systemctl --no-pager status jenkins-agent
HELPER
chmod 0755 /usr/local/bin/setup-jenkins-agent
