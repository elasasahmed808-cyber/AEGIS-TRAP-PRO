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
retry dnf install -y git python3 python3-pip tar gzip wget amazon-cloudwatch-agent amazon-efs-utils
systemctl enable --now amazon-ssm-agent || true

# ---- Java 21 (Jenkins requires 21 or 25) ----
retry dnf install -y fontconfig java-21-amazon-corretto-headless
java -version 2>&1 | grep -q 'version "21'

# ---- Jenkins LTS (package install only - do not start yet) ----
retry wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/rpm-stable/jenkins.repo
dnf clean all
retry dnf -y makecache
retry dnf install -y jenkins
rpm -q jenkins
id jenkins
systemctl stop jenkins || true

# ---- Persistent JENKINS_HOME -----------------------------------------
# /var/lib/jenkins is where Jenkins keeps every job, every credential/API
# token, every plugin and every user account. It used to live on the
# instance's own root disk, so all of that was lost every time the
# instance was replaced. It is mounted from EFS here instead: a brand-new
# instance that mounts the same filesystem id comes back up as the exact
# same Jenkins the previous instance was (same jobs, same token), because
# it is reading the same files, not a freshly-initialized empty directory.
mkdir -p /var/lib/jenkins
if ! mountpoint -q /var/lib/jenkins; then
  retry mount -t efs -o tls "${efs_id}:/" /var/lib/jenkins
fi
grep -q "${efs_id}" /etc/fstab || echo "${efs_id}:/ /var/lib/jenkins efs _netdev,tls 0 0" >> /etc/fstab
chown -R jenkins:jenkins /var/lib/jenkins

mkdir -p /etc/systemd/system/jenkins.service.d /var/log/jenkins
cat > /etc/systemd/system/jenkins.service.d/env.conf <<'DROP'
[Service]
Environment="AWS_REGION=${region}"
Environment="ARTIFACT_BUCKET=${artifact_bucket}"
Environment="ARTIFACT_KEY=${artifact_key}"
Environment="JENKINS_OPTS=--prefix=/jenkins"
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

# ---- Keep the GitHub Actions trigger token in sync on every boot -----
# This is the fix for "a new Jenkins instance can't be triggered by
# GitHub Actions anymore": the token GitHub Actions sends never lives only
# on the instance. Terraform creates it once and stores it in SSM
# Parameter Store. This script re-reads it on every boot (new instance or
# not) and writes it onto the Jenkins job, so the job's remote-trigger
# token always matches what GitHub Actions already has, with nothing to
# update by hand. Combined with the EFS mount above, the job itself also
# now survives instance replacement, so after the very first manual setup
# this requires no further action, ever.
mkdir -p /var/lib/jenkins/init.groovy.d
TRIGGER_TOKEN="$(aws ssm get-parameter --name '${trigger_token_param}' --with-decryption --region '${region}' --query Parameter.Value --output text)"
cat > /var/lib/jenkins/init.groovy.d/sync-trigger-token.groovy <<GROOVY
import jenkins.model.Jenkins

def jobName = "${trigger_job_name}"
def token = "$TRIGGER_TOKEN"
def job = Jenkins.instance.getItemByFullName(jobName)

if (job == null) {
    println("sync-trigger-token: job '" + jobName + "' does not exist yet - nothing to sync. Create the Pipeline job once (see README); this script will keep its token in sync on every boot after that.")
} else {
    job.setAuthToken(token)
    job.save()
    println("sync-trigger-token: remote-trigger token for '" + jobName + "' synced from SSM")
}
GROOVY
chown -R jenkins:jenkins /var/lib/jenkins/init.groovy.d

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
