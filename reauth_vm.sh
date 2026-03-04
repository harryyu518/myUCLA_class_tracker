#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
VM_REPO="${VM_REPO:-$REPO_ROOT}"
SERVICE_NAME="${SERVICE_NAME:-myucla-monitor}"
RESTART_SERVICE="${RESTART_SERVICE:-1}"
VM_USER="${VM_USER:-}"
VM_IP="${VM_IP:-}"
SSH_KEY="${SSH_KEY:-}"
REMOTE_REPO="${REMOTE_REPO:-}"
SYNC_ENV_LOCAL="${SYNC_ENV_LOCAL:-1}"
REMOTE_HELPER_SCRIPT="${REMOTE_HELPER_SCRIPT:-/tmp/myucla_reauth_vm.sh}"
STOP_LOCAL_MONITOR="${STOP_LOCAL_MONITOR:-1}"
LOCAL_SERVICE_LABEL="${LOCAL_SERVICE_LABEL:-com.myucla.classsearch.monitor}"
SNAPSHOT_SOURCE_MODE="${SNAPSHOT_SOURCE_MODE:-vm}"
SNAPSHOT_SOURCE_FILE="${SNAPSHOT_SOURCE_FILE:-$VM_REPO/snapshots/.active_source}"

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

stop_local_monitor_processes() {
  if has_cmd launchctl; then
    local target="gui/$(id -u)/$LOCAL_SERVICE_LABEL"
    if launchctl print "$target" >/dev/null 2>&1; then
      launchctl bootout "$target" >/dev/null 2>&1 || true
      log "Stopped local LaunchAgent: $LOCAL_SERVICE_LABEL"
    else
      log "Local LaunchAgent not loaded: $LOCAL_SERVICE_LABEL"
    fi
  fi

  if has_cmd pkill; then
    pkill -f "monitor_classsearch.py" >/dev/null 2>&1 || true
    pkill -f "run_monitor_classsearch.sh" >/dev/null 2>&1 || true
    log "Stopped local ClassSearch monitor process(es) if running"
  fi
}

expand_home_path() {
  local raw_path="$1"
  if [[ "$raw_path" == "~" ]]; then
    printf '%s\n' "$HOME"
    return
  fi
  if [[ "$raw_path" == "~/"* ]]; then
    printf '%s/%s\n' "$HOME" "${raw_path#\~/}"
    return
  fi
  printf '%s\n' "$raw_path"
}

read_env_key() {
  local env_file="$1"
  local key_name="$2"
  awk -F= -v lookup_key="$key_name" '
    /^[[:space:]]*#/ { next }
    NF < 2 { next }
    {
      key = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key != lookup_key) {
        next
      }
      value = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /^".*"$/ || value ~ /^'\''.*'\''$/) {
        value = substr(value, 2, length(value) - 2)
      }
      print value
      exit
    }
  ' "$env_file"
}

prepare_snapshots_for_mode() {
  local mode="$1"
  local source_file="$2"
  local snapshot_root
  local previous_mode=""

  snapshot_root="$(dirname "$source_file")"
  mkdir -p "$snapshot_root"

  if [[ -f "$source_file" ]]; then
    previous_mode="$(tr -d '[:space:]' <"$source_file")"
  fi

  if [[ -n "$previous_mode" ]] && [[ "$previous_mode" != "$mode" ]]; then
    log "Snapshot source changed (${previous_mode} -> ${mode}); clearing ClassSearch snapshots"
    find "$snapshot_root" -maxdepth 1 -type f \
      \( -name "classsearch_[0-9]*.html" -o -name "classsearch_sso_*.html" \) -delete || true
    find "$snapshot_root" -mindepth 2 -maxdepth 2 -type f \
      \( -name "classsearch_[0-9]*.html" -o -name "classsearch_sso_*.html" \) -delete || true
  fi

  printf '%s\n' "$mode" >"$source_file"

  ./venv/bin/python -u - <<'PY'
import config
import utils

targets = utils.build_classsearch_targets(config.CLASSSEARCH_URLS, config.SNAPSHOTS_DIR)
for target in targets:
    utils.rotate_snapshots_by_patterns(
        target["snapshot_dir"],
        [config.CLASSSEARCH_SNAPSHOT_PATTERN, config.CLASSSEARCH_SSO_SNAPSHOT_PATTERN],
        config.MAX_SNAPSHOTS_TO_KEEP,
    )

print(f"Snapshot retention enforced: keep={config.MAX_SNAPSHOTS_TO_KEEP} per class")
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

require_file "$VM_REPO/venv/bin/python"
require_file "$VM_REPO/.env.local"

cd "$VM_REPO"

# Convenience: allow VM connection settings from .env.local so ./reauth_vm.sh
# works without inline env vars on local machines.
if [[ -f "$VM_REPO/.env.local" ]]; then
  if [[ -z "$VM_IP" ]]; then
    VM_IP="$(read_env_key "$VM_REPO/.env.local" "VM_IP")"
  fi
  if [[ -z "$VM_USER" ]]; then
    VM_USER="$(read_env_key "$VM_REPO/.env.local" "VM_USER")"
  fi
  if [[ -z "$SSH_KEY" ]]; then
    SSH_KEY="$(read_env_key "$VM_REPO/.env.local" "SSH_KEY")"
  fi
  if [[ -z "$REMOTE_REPO" ]]; then
    REMOTE_REPO="$(read_env_key "$VM_REPO/.env.local" "REMOTE_REPO")"
  fi
fi

VM_USER="${VM_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
REMOTE_REPO="${REMOTE_REPO:-~/myucla_tracker}"
SSH_KEY="$(expand_home_path "$SSH_KEY")"

if has_cmd systemctl && has_cmd journalctl; then
  require_cmd sudo
  require_file "$VM_REPO/storage.json"

  if [[ "$RESTART_SERVICE" == "1" ]]; then
    log "Stopping VM service before preflight to avoid local+VM overlap"
    sudo systemctl stop "$SERVICE_NAME"
  fi

  log "Validating .env.local required keys and runtime settings"
  validate_env_file "$VM_REPO/.env.local"
  prepare_snapshots_for_mode "$SNAPSHOT_SOURCE_MODE" "$SNAPSHOT_SOURCE_FILE"

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

[[ -n "$VM_IP" ]] || die "VM_IP is required when running from local (example: VM_IP=203.0.113.10 ./reauth_vm.sh)"

if [[ -n "$SSH_KEY" ]]; then
  require_file "$SSH_KEY"
fi

if [[ "$STOP_LOCAL_MONITOR" == "1" ]]; then
  log "Stopping local monitor before VM re-auth to avoid local+VM overlap"
  stop_local_monitor_processes
fi

if [[ "$RESTART_SERVICE" == "1" ]]; then
  log "Stopping VM service before local re-auth to avoid local+VM overlap"
  ssh -i "$SSH_KEY" "$VM_USER@$VM_IP" "sudo systemctl stop '$SERVICE_NAME'"
fi

log "Validating .env.local required keys and runtime settings"
validate_env_file "$VM_REPO/.env.local"
prepare_snapshots_for_mode "$SNAPSHOT_SOURCE_MODE" "$SNAPSHOT_SOURCE_FILE"

log "Starting interactive local re-auth (complete UCLA + Duo, then press Enter)"
LOGIN_SAVE_SCRIPT="$VM_REPO/login_save.py"
require_file "$LOGIN_SAVE_SCRIPT"
./venv/bin/python "$LOGIN_SAVE_SCRIPT"

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

log "Uploading reauth_vm.sh helper to ${SSH_TARGET}:${REMOTE_HELPER_SCRIPT}"
scp "${SSH_OPTS[@]}" "$VM_REPO/reauth_vm.sh" "${SSH_TARGET}:${REMOTE_HELPER_SCRIPT}"

log "Running VM re-auth script remotely (preflight + restart + logs)"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
  "cd $REMOTE_REPO && RESTART_SERVICE=1 SERVICE_NAME='$SERVICE_NAME' VM_REPO=\"\$(pwd)\" bash '$REMOTE_HELPER_SCRIPT'"

log "Done"
