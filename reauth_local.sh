#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
LOCAL_REPO="${LOCAL_REPO:-$REPO_ROOT}"
LOCAL_SERVICE_LABEL="${LOCAL_SERVICE_LABEL:-com.myucla.classsearch.monitor}"
STOP_LOCAL_MONITOR="${STOP_LOCAL_MONITOR:-0}"
RESTART_LOCAL_MONITOR="${RESTART_LOCAL_MONITOR:-1}"
AUTO_START_LOCAL_MONITOR="${AUTO_START_LOCAL_MONITOR:-1}"
LOCAL_MONITOR_LOG="${LOCAL_MONITOR_LOG:-$LOCAL_REPO/monitor_classsearch.local.log}"
SERVICE_NAME="${SERVICE_NAME:-myucla-monitor}"
STOP_REMOTE_VM_MONITOR="${STOP_REMOTE_VM_MONITOR:-1}"
VM_USER="${VM_USER:-}"
VM_IP="${VM_IP:-}"
SSH_KEY="${SSH_KEY:-}"
SNAPSHOT_SOURCE_MODE="${SNAPSHOT_SOURCE_MODE:-local}"
SNAPSHOT_SOURCE_FILE="${SNAPSHOT_SOURCE_FILE:-$LOCAL_REPO/snapshots/.active_source}"

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

launch_agent_target() {
  printf 'gui/%s/%s' "$(id -u)" "$LOCAL_SERVICE_LABEL"
}

is_launch_agent_loaded() {
  launchctl print "$(launch_agent_target)" >/dev/null 2>&1
}

ensure_local_monitor_running() {
  local started=0

  if has_cmd launchctl; then
    local target
    target="$(launch_agent_target)"
    if is_launch_agent_loaded; then
      log "Restarting local LaunchAgent monitor"
      launchctl kickstart -k "$target" || true
      started=1
    else
      local plist="$HOME/Library/LaunchAgents/$LOCAL_SERVICE_LABEL.plist"
      if [[ -f "$plist" ]]; then
        log "Loading local LaunchAgent from $plist"
        launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
        launchctl kickstart -k "$target" >/dev/null 2>&1 || true
        if is_launch_agent_loaded; then
          log "Started local LaunchAgent monitor: $LOCAL_SERVICE_LABEL"
          started=1
        fi
      fi
    fi
  fi

  if [[ "$started" == "0" ]]; then
    if has_cmd pgrep && pgrep -f "monitor_classsearch.py" >/dev/null 2>&1; then
      log "Local monitor process already running; skipping direct start"
      return
    fi
    log "Starting local monitor directly (no active LaunchAgent)"
    nohup "$LOCAL_REPO/run_monitor_classsearch.sh" >>"$LOCAL_MONITOR_LOG" 2>&1 &
    log "Local monitor started (pid=$!, log=$LOCAL_MONITOR_LOG)"
  fi
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
    "MAX_SNAPSHOTS_TO_KEEP",
    "PLAYWRIGHT_TIMEOUT",
    "PLAYWRIGHT_HEADLESS",
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

require_cmd shasum
require_file "$LOCAL_REPO/venv/bin/python"
require_file "$LOCAL_REPO/.env.local"
require_file "$LOCAL_REPO/login_save.py"

cd "$LOCAL_REPO"

# Load optional VM connection settings from .env.local.
if [[ -f "$LOCAL_REPO/.env.local" ]]; then
  if [[ -z "$VM_IP" ]]; then
    VM_IP="$(read_env_key "$LOCAL_REPO/.env.local" "VM_IP")"
  fi
  if [[ -z "$VM_USER" ]]; then
    VM_USER="$(read_env_key "$LOCAL_REPO/.env.local" "VM_USER")"
  fi
  if [[ -z "$SSH_KEY" ]]; then
    SSH_KEY="$(read_env_key "$LOCAL_REPO/.env.local" "SSH_KEY")"
  fi
fi

VM_USER="${VM_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_KEY="$(expand_home_path "$SSH_KEY")"

if [[ "$STOP_REMOTE_VM_MONITOR" == "1" ]] && [[ -n "$VM_IP" ]]; then
  require_cmd ssh
  require_file "$SSH_KEY"
  log "Stopping VM service before local re-auth to avoid local+VM overlap"
  ssh -i "$SSH_KEY" "$VM_USER@$VM_IP" "sudo systemctl stop '$SERVICE_NAME'"
fi

log "Validating .env.local required keys and runtime settings"
validate_env_file "$LOCAL_REPO/.env.local"
prepare_snapshots_for_mode "$SNAPSHOT_SOURCE_MODE" "$SNAPSHOT_SOURCE_FILE"

if [[ "$STOP_LOCAL_MONITOR" == "1" ]] && command -v launchctl >/dev/null 2>&1; then
  log "Stopping local LaunchAgent monitor before re-auth"
  launchctl bootout "gui/$(id -u)/$LOCAL_SERVICE_LABEL" 2>/dev/null || true
fi
if [[ "$STOP_LOCAL_MONITOR" == "1" ]] && has_cmd pkill; then
  pkill -f "monitor_classsearch.py" >/dev/null 2>&1 || true
fi

log "Starting interactive local re-auth (complete UCLA + Duo, then press Enter)"
./venv/bin/python login_save.py

require_file "$LOCAL_REPO/storage.json"
STORAGE_SHA="$(shasum -a 256 "$LOCAL_REPO/storage.json" | awk '{print $1}')"
log "Local storage.json SHA256: $STORAGE_SHA"

log "Running local preflight is_sso check for all configured ClassSearch URLs"
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

if [[ "$RESTART_LOCAL_MONITOR" == "1" ]] || [[ "$AUTO_START_LOCAL_MONITOR" == "1" ]]; then
  ensure_local_monitor_running
fi

log "Done"
