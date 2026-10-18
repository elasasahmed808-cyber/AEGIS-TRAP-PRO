#!/bin/bash
# documind-deploy - runs at boot AND via SSM Run Command from Jenkins.
set -euo pipefail
source /etc/documind/config.env

BASE=/opt/documind
REL="$BASE/releases/$(date +%Y%m%d%H%M%S)"
TMP="$(mktemp /tmp/documind.XXXXXX.tar.gz)"
trap 'rm -f "$TMP"' EXIT

echo "[deploy] pulling s3://$ARTIFACT_BUCKET/$ARTIFACT_KEY"
aws s3 cp "s3://$ARTIFACT_BUCKET/$ARTIFACT_KEY" "$TMP" --region "$AWS_REGION" --only-show-errors

mkdir -p "$REL"
tar -xzf "$TMP" -C "$REL"
python3 -m venv "$REL/venv"
"$REL/venv/bin/pip" install --quiet --upgrade pip
"$REL/venv/bin/pip" install --quiet -r "$REL/requirements.txt"

ln -sfn "$REL" "$BASE/current"
systemctl restart documind

for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8080/health >/dev/null; then
    echo "[deploy] healthy: $REL"
    ls -1dt "$BASE"/releases/* | tail -n +4 | xargs -r rm -rf   # keep last 3
    exit 0
  fi
  sleep 2
done
echo "[deploy] health check FAILED" >&2
exit 1
