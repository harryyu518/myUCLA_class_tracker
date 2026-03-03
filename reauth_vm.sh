#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
VM_REPO="${VM_REPO:-$REPO_ROOT}"
SERVICE_NAME="${SERVICE_NAME:-myucla-monitor}"
RESTART_SERVICE="${RESTART_SERVICE:-1}"
VM_USER="${VM_USER:-ubuntu}"
VM_IP="${VM_IP:-64.181.255.201}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
REMOTE_REPO="${REMOTE_REPO:-~/myucla_tracker}"
SYNC_ENV_LOCAL="${SYNC_ENV_LOCAL:-1}"

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

has_cmd() {
  local cmd_name="$1"
  command -v "$cmd_name" >/dev/null 2>&1
}

run_preflight_check() {
  ./venv/bin/python -u - <<'PY'
import config
import utils

targets = utils.build_classsearch_targets(config.CLASSSEARCH_URLS, config.SNAPSHOTS_DIR)
if not targets:
    print("No ClassSearch URLs configured in .env.local or .env")
    raise SystemExit(2)

session = utils.PlaywrightSession(config.STORAGE_FILE)
bad = []
try:
    session.start()
    for target in targets:
        name = str(target["name"])
        url = str(target["url"])
        html = session.fetch(url)
        is_sso = utils.is_sso_page(html)
        status_rows = len(utils.extract_classsearch_status_map(html))
        print(f"{name}: is_sso={is_sso} status_rows={status_rows}")
        if is_sso:
            bad.append(name)
finally:
    session.close()

if bad:
    print("Preflight failed: SSO still detected for:", ", ".join(bad))
    raise SystemExit(3)

print("Preflight passed: all targets returned non-SSO pages")
PY
}

validate_env_file() {
  local env_file="$1"
  ./venv/bin/python - "$env_file" <<'PY'
import sys
from pathlib import Path


env_file = Path(sys.argv[1])
parsed: dict[str, str] = {}
for raw_line in env_file.read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    parsed[key.strip()] = value.strip().strip('"').strip("'")

required_non_empty = [
    "CLASSSEARCH_POLL_INTERVAL",
    "CLASSPLANNER_POLL_INTERVAL",
    "MAX_SNAPSHOTS_TO_KEEP",
    "PLAYWRIGHT_TIMEOUT",
    "PLAYWRIGHT_HEADLESS",
    "CLASSPLANNER_URL",
    "CLASSPLANNER_LOGIN_URL",
    "CLASSPLANNER_CSS_SELECTOR",
    "PUSHOVER_API_URL",
]

missing = [key for key in required_non_empty if not parsed.get(key, "").strip()]
if not any(parsed.get(f"CLASSSEARCH_URL_{index}", "").strip() for index in range(1, 11)):
    missing.append("CLASSSEARCH_URL_1..CLASSSEARCH_URL_10 (at least one non-empty value)")

if missing:
    print("Missing required .env.local values:")
    for item in missing:
        print(f"- {item}")
    raise SystemExit(2)

# Import config to verify numeric/bool parsing and value wiring.
import config  # noqa: E402

if not config.CLASSSEARCH_URLS:
    raise SystemExit("No valid ClassSearch URLs after parsing .env.local")

print(
    f"Validated .env.local (targets={len(config.CLASSSEARCH_URLS)}, "
    f"classsearch_poll={config.CLASSSEARCH_POLL_INTERVAL}s)"
)
PY
}

require_file "$VM_REPO/venv/bin/python"
require_file "$VM_REPO/.env.local"

cd "$VM_REPO"

if has_cmd systemctl && has_cmd journalctl; then
  require_cmd sudo
  require_file "$VM_REPO/storage.json"

  log "Validating .env.local required keys and runtime settings"
  validate_env_file "$VM_REPO/.env.local"

  log "Running VM preflight is_sso check for all configured ClassSearch URLs"
  run_preflight_check

  if [[ "$RESTART_SERVICE" == "1" ]]; then
    log "Restarting VM service: $SERVICE_NAME"
    sudo systemctl restart "$SERVICE_NAME"
  fi

  sleep 3
  log "Recent service logs (last 2 minutes)"
  sudo journalctl -u "$SERVICE_NAME" --since "2 minutes ago" -l --no-pager

  log "Recent snapshots on VM"
  find snapshots -maxdepth 2 -type f -name "classsearch*.html" | sort | tail -n 20

  log "Done"
  exit 0
fi

require_cmd ssh
require_cmd scp
require_cmd shasum
require_file "$VM_REPO/login_save.py"

if [[ -n "$SSH_KEY" ]]; then
  require_file "$SSH_KEY"
fi

log "Validating .env.local required keys and runtime settings"
validate_env_file "$VM_REPO/.env.local"

log "Starting interactive local re-auth (complete UCLA + Duo, then press Enter)"
./venv/bin/python login_save.py

require_file "$VM_REPO/storage.json"
STORAGE_SHA="$(shasum -a 256 "$VM_REPO/storage.json" | awk '{print $1}')"
log "Local storage.json SHA256: $STORAGE_SHA"

log "Running local preflight is_sso check for all configured ClassSearch URLs"
run_preflight_check

SSH_TARGET="${VM_USER}@${VM_IP}"
SSH_OPTS=()
if [[ -n "$SSH_KEY" ]]; then
  SSH_OPTS=(-i "$SSH_KEY")
fi

log "Uploading storage.json to ${SSH_TARGET}:${REMOTE_REPO}/storage.json"
scp "${SSH_OPTS[@]}" "$VM_REPO/storage.json" "${SSH_TARGET}:${REMOTE_REPO}/storage.json"

if [[ "$SYNC_ENV_LOCAL" == "1" ]]; then
  log "Uploading .env.local to ${SSH_TARGET}:${REMOTE_REPO}/.env.local"
  scp "${SSH_OPTS[@]}" "$VM_REPO/.env.local" "${SSH_TARGET}:${REMOTE_REPO}/.env.local"
fi

log "Uploading reauth_vm.sh to ${SSH_TARGET}:${REMOTE_REPO}/reauth_vm.sh"
scp "${SSH_OPTS[@]}" "$VM_REPO/reauth_vm.sh" "${SSH_TARGET}:${REMOTE_REPO}/reauth_vm.sh"

log "Running VM re-auth script remotely (preflight + restart + logs)"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
  "cd $REMOTE_REPO && \
   if [[ -f ./reauth_vm.sh ]]; then \
     RESTART_SERVICE=1 SERVICE_NAME='$SERVICE_NAME' bash ./reauth_vm.sh; \
   elif [[ -f ./scripts/vm/reauth_vm.sh ]]; then \
     RESTART_SERVICE=1 SERVICE_NAME='$SERVICE_NAME' bash ./scripts/vm/reauth_vm.sh; \
   else \
     echo 'ERROR: Could not find reauth_vm.sh on VM' >&2; \
     exit 1; \
   fi"

log "Done"
