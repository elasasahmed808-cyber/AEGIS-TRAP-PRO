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
BEDROCK_MODEL_ID=${bedrock_model_id}
GUARDRAIL_ID=${guardrail_id}
GUARDRAIL_VERSION=${guardrail_version}
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
echo '${deploy_b64}' | base64 -d > /usr/local/bin/documind-deploy
chmod 755 /usr/local/bin/documind-deploy

# ---- systemd unit: Flask on gunicorn :8080 ----
cat > /etc/systemd/system/documind.service <<'UNIT'
[Unit]
Description=DocuMind (gunicorn)
After=network-online.target
Wants=network-online.target

[Service]
User=documind
Group=documind
WorkingDirectory=/opt/documind/current
EnvironmentFile=/etc/documind/config.env
ExecStart=/opt/documind/current/venv/bin/gunicorn --bind 0.0.0.0:8080 --workers 2 --access-logfile /var/log/documind/access.log --error-logfile /var/log/documind/error.log app:app
Restart=always
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable documind

# ---- CloudWatch agent ----
echo '${cw_b64}' | base64 -d > /opt/aws/amazon-cloudwatch-agent/etc/cw.json
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/cw.json -s

# ---- Deploy the app NOW (default behaviour) ----
/usr/local/bin/documind-deploy
