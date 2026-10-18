#!/bin/bash
set -Eeuxo pipefail
exec > >(tee /var/log/jenkins-bootstrap.log) 2>&1
trap 'echo "BOOTSTRAP FAILED at line $LINENO: $BASH_COMMAND"' ERR

retry() {
  local n=0
  until "$@"; do
    n=$((n+1))
    if [ "$n" -ge 5 ]; then
      echo "FAILED after 5 attempts: $*"
      return 1
    fi
    sleep 10
  done
}

# ---- Base packages (curl omitted: AL2023 ships curl-minimal) ----
retry dnf install -y git python3 python3-pip tar gzip wget amazon-cloudwatch-agent
systemctl enable --now amazon-ssm-agent || true

# ---- Java 21 (Jenkins requires 21 or 25) ----
retry dnf install -y fontconfig java-21-amazon-corretto-headless
java -version 2>&1 | grep -q 'version "21'

# ---- Jenkins LTS ----
retry wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/rpm-stable/jenkins.repo
dnf clean all
retry dnf -y makecache
retry dnf install -y jenkins
rpm -q jenkins
id jenkins

mkdir -p /etc/systemd/system/jenkins.service.d /var/log/jenkins
cat > /etc/systemd/system/jenkins.service.d/env.conf <<'DROP'
[Service]
Environment="AWS_REGION=${region}"
Environment="ARTIFACT_BUCKET=${artifact_bucket}"
Environment="ARTIFACT_KEY=${artifact_key}"
DROP
chown jenkins:jenkins /var/log/jenkins

# ---- Canary 2 ----
mkdir -p /opt/documind
cat > /opt/documind/.env.bak <<'CANARY'
AWS_ACCESS_KEY_ID=${canary_key_id}
AWS_SECRET_ACCESS_KEY=${canary_secret}
AWS_DEFAULT_REGION=${region}
CANARY
chown root:root /opt/documind/.env.bak
chmod 600 /opt/documind/.env.bak

# ---- CloudWatch agent ----
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
echo '${cw_b64}' | base64 -d > /opt/aws/amazon-cloudwatch-agent/etc/cw.json
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/cw.json -s

# ---- Start Jenkins ----
systemctl daemon-reload
systemctl enable --now jenkins

for i in $(seq 1 30); do
  if systemctl is-active --quiet jenkins; then
    echo "Jenkins is active"
    break
  fi
  sleep 10
done
systemctl is-active jenkins

# ---- Optional security tools (isolated venv, must not block Jenkins) ----
if python3 -m venv /opt/sectools && retry /opt/sectools/bin/pip install bandit pip-audit; then
  ln -sf /opt/sectools/bin/bandit /usr/local/bin/bandit
  ln -sf /opt/sectools/bin/pip-audit /usr/local/bin/pip-audit
else
  echo "WARNING: security tools failed to install, continuing"
fi

echo "Bootstrap finished OK"