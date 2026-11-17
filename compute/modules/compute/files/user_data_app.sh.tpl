#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/documind-bootstrap.log) 2>&1

dnf install -y python3 python3-pip tar gzip amazon-cloudwatch-agent
systemctl enable --now amazon-ssm-agent || true

id documind || useradd --system --home-dir /opt/documind --shell /sbin/nologin documind
mkdir -p /opt/documind/releases /etc/documind /var/log/documind
chmod 755 /opt/documind
chown documind:documind /var/log/documind

cat > /etc/documind/config.env <<'CFG'
AWS_REGION=${region}
ARTIFACT_BUCKET=${artifact_bucket}
ARTIFACT_KEY=${artifact_key}
SUMMARIES_BUCKET=${summaries_bucket}
SUMMARIES_PREFIX=${summaries_prefix}
APMIX_API_KEY_PARAM=${apmix_api_key_param}
CFG
chmod 644 /etc/documind/config.env

# ---- Canary 2: root-only file the app never reads ----
cat > /opt/documind/.env.bak <<'CANARY'
AWS_ACCESS_KEY_ID=${canary_key_id}
AWS_SECRET_ACCESS_KEY=${canary_secret}
AWS_DEFAULT_REGION=${region}
CANARY
chown root:root /opt/documind/.env.bak
chmod 600 /opt/documind/.env.bak

# ---- deploy script (same one Jenkins triggers through SSM) ----
# IMPORTANT: strip any CR bytes on decode. A CRLF shebang ("#!/bin/bash\r")
# makes the kernel look for an interpreter literally named "bash\r", which
# fails with "cannot execute: required file not found" - the exact failure
# that left this host with no /opt/documind/current symlink at all.
echo '${deploy_b64}' | base64 -d | tr -d '\r' > /usr/local/bin/documind-deploy
chmod 755 /usr/local/bin/documind-deploy

# Hard guard: verify the script is actually executable text before relying on
# it anywhere below. Fail the boot loudly instead of silently limping on.
head -c2 /usr/local/bin/documind-deploy | grep -q '^#!' || {
    echo "FATAL: /usr/local/bin/documind-deploy has no valid shebang after decode" >&2
    exit 1
}
bash -n /usr/local/bin/documind-deploy || {
    echo "FATAL: /usr/local/bin/documind-deploy failed syntax check" >&2
    exit 1
}

# ---- systemd unit: one-shot deploy that MUST succeed before the app starts ----
cat > /etc/systemd/system/documind-deploy.service <<'UNIT'
[Unit]
Description=Deploy DocuMind release (pulls artifact, builds venv, verifies gunicorn)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/documind-deploy --boot
RemainAfterExit=yes
# Keep boot-time failures visible instead of hanging forever
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
UNIT

# ---- systemd unit: Flask on gunicorn :8080 - now genuinely cannot start ----
# ---- until documind-deploy.service has succeeded, since Requires= makes a ----
# ---- failed dependency block this unit instead of racing it. ----
cat > /etc/systemd/system/documind.service <<'UNIT'
[Unit]
Description=DocuMind (gunicorn)
After=network-online.target documind-deploy.service
Requires=documind-deploy.service
# Give up after sustained failure instead of hammering systemd's start-rate
# limit into "Start request repeated too quickly" (what happened today) -
# these two keys belong in [Unit], not [Service] - this way
# `systemctl status documind` stays informative instead of locked.
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
User=documind
Group=documind
WorkingDirectory=/opt/documind/current
EnvironmentFile=/etc/documind/config.env
ExecStart=/opt/documind/current/venv/bin/gunicorn --bind 0.0.0.0:8080 --workers 2 --access-logfile /var/log/documind/access.log --error-logfile /var/log/documind/error.log app:app
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable documind-deploy
systemctl enable documind

# ---- CloudWatch agent ----
echo '${cw_b64}' | base64 -d | tr -d '\r' > /opt/aws/amazon-cloudwatch-agent/etc/cw.json
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/cw.json -s

# ---- Deploy + start the app NOW, synchronously, failing the boot loudly on error ----
systemctl start documind-deploy
systemctl start documind
systemctl is-active documind
