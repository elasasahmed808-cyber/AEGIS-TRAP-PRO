#!/bin/bash
# documind-deploy
#   documind-deploy --boot   : used by documind-deploy.service. Builds the release and
#                              flips the 'current' symlink ONLY. documind.service starts
#                              AFTER this unit, so restarting/health-checking here would
#                              deadlock (the unit can't finish until the app is healthy,
#                              and the app can't start until the unit finishes).
#   documind-deploy          : used by Jenkins via SSM Run Command. Full deploy:
#                              build, flip symlink, restart app, wait for /health.
set -euo pipefail
MODE="${1:-full}"
source /etc/documind/config.env

BASE=/opt/documind
REL="$BASE/releases/$(date +%Y%m%d%H%M%S)"
TMP="$(mktemp /tmp/documind.XXXXXX.tar.gz)"
trap 'rm -f "$TMP"' EXIT

echo "[deploy] mode=$MODE region=$AWS_REGION"
echo "[deploy] pulling s3://$ARTIFACT_BUCKET/$ARTIFACT_KEY"
aws s3 cp "s3://$ARTIFACT_BUCKET/$ARTIFACT_KEY" "$TMP" --region "$AWS_REGION" --only-show-errors

mkdir -p "$REL"
tar -xzf "$TMP" -C "$REL"

python3 -m venv "$REL/venv"
if [ ! -x "$REL/venv/bin/python3" ]; then
    echo "[deploy] FATAL: venv creation failed (no $REL/venv/bin/python3)" >&2
    rm -rf "$REL"
    exit 1
fi

"$REL/venv/bin/pip" install --quiet --upgrade pip
"$REL/venv/bin/pip" install --quiet -r "$REL/requirements.txt"

# Never point 'current' at a release with no working gunicorn.
if [ ! -x "$REL/venv/bin/gunicorn" ]; then
    echo "[deploy] FATAL: gunicorn not found/executable at $REL/venv/bin/gunicorn" >&2
    rm -rf "$REL"
    exit 1
fi

ln -sfn "$REL" "$BASE/current"

prune() { ls -1dt "$BASE"/releases/* | tail -n +4 | xargs -r rm -rf; }   # keep last 3

if [ "$MODE" = "--boot" ]; then
    echo "[deploy] boot mode: release ready, documind.service will start next: $REL"
    prune
    exit 0
fi

systemctl restart documind

for i in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:8080/health >/dev/null 2>&1; then
        echo "[deploy] healthy: $REL"
        prune
        exit 0
    fi
    sleep 2
done
echo "[deploy] health check FAILED" >&2
systemctl status documind --no-pager -l >&2 || true
exit 1