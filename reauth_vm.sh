#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOCAL_REPO="${LOCAL_REPO:-$SCRIPT_DIR}"
VM_IP="${VM_IP:-<VM_IP>}"
VM_USER="${VM_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-<SSH_KEY_PATH>}"
REMOTE_REPO="${REMOTE_REPO:-/home/$VM_USER/myucla_tracker}"
SERVICE_NAME="${SERVICE_NAME:-myucla-monitor}"
SKIP_LOCAL_STOP="${SKIP_LOCAL_STOP:-0}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_file() {
  local file_path="$1"
  [[ -f "$file_path" ]] || die "Missing required file: $file_path"
}

require_cmd() {
  local cmd_name="$1"
  command -v "$cmd_name" >/dev/null 2>&1 || die "Missing required command: $cmd_name"
}

require_cmd ssh
require_cmd scp
require_cmd shasum
require_file "$SSH_KEY"
require_file "$LOCAL_REPO/venv/bin/python"

cd "$LOCAL_REPO"

if [[ "$SKIP_LOCAL_STOP" != "1" ]] && command -v launchctl >/dev/null 2>&1; then
  log "Stopping local LaunchAgent monitor (optional safety)"
  launchctl bootout "gui/$(id -u)/com.myucla.classsearch.monitor" 2>/dev/null || true
fi

log "Starting interactive re-auth (complete UCLA + Duo, then press Enter in terminal)"
./venv/bin/python login_save.py

require_file "$LOCAL_REPO/storage.json"
LOCAL_SHA="$(shasum -a 256 "$LOCAL_REPO/storage.json" | awk '{print $1}')"
log "Local storage.json SHA256: $LOCAL_SHA"

log "Copying storage.json to VM"
scp -i "$SSH_KEY" "$LOCAL_REPO/storage.json" "$VM_USER@$VM_IP:$REMOTE_REPO/storage.json"

REMOTE_SHA="$(ssh -i "$SSH_KEY" "$VM_USER@$VM_IP" "sha256sum '$REMOTE_REPO/storage.json' | awk '{print \$1}'")"
log "Remote storage.json SHA256: $REMOTE_SHA"

if [[ "$LOCAL_SHA" != "$REMOTE_SHA" ]]; then
  die "Checksum mismatch after copy (local != remote)"
fi

log "Running VM preflight is_sso check for all configured ClassSearch URLs"
ssh -i "$SSH_KEY" "$VM_USER@$VM_IP" "cd '$REMOTE_REPO' && ./venv/bin/python - <<'PY'
import config
import utils


targets = utils.build_classsearch_targets(config.CLASSSEARCH_URLS, config.SNAPSHOTS_DIR)
if not targets:
    print('No ClassSearch URLs configured in config.py')
    raise SystemExit(2)

session = utils.PlaywrightSession(config.STORAGE_FILE)
bad = []
try:
    session.start()
    for target in targets:
        name = str(target['name'])
        url = str(target['url'])
        html = session.fetch(url)
        is_sso = utils.is_sso_page(html)
        status_rows = len(utils.extract_classsearch_status_map(html))
        print(f'{name}: is_sso={is_sso} status_rows={status_rows}')
        if is_sso:
            bad.append(name)
finally:
    session.close()

if bad:
    print('Preflight failed: SSO still detected for:', ', '.join(bad))
    raise SystemExit(3)

print('Preflight passed: all targets returned non-SSO pages')
PY"

log "Restarting VM service: $SERVICE_NAME"
ssh -i "$SSH_KEY" "$VM_USER@$VM_IP" "sudo systemctl restart '$SERVICE_NAME'"

sleep 5

log "Recent service logs (last 2 minutes)"
ssh -i "$SSH_KEY" "$VM_USER@$VM_IP" "sudo journalctl -u '$SERVICE_NAME' --since '2 minutes ago' -l --no-pager"

log "Recent snapshots on VM"
ssh -i "$SSH_KEY" "$VM_USER@$VM_IP" "cd '$REMOTE_REPO' && find snapshots -maxdepth 2 -type f -name 'classsearch*.html' | sort | tail -n 20"

log "Done"
