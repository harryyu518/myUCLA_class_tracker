#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
VM_REPO="${VM_REPO:-$REPO_ROOT}"

ACTION="${1:-start}"

PID_FILE="${PID_FILE:-$VM_REPO/.vm_snapshot_sync.pid}"
LOG_FILE="${LOG_FILE:-$VM_REPO/vm_snapshot_sync.log}"
LOCAL_SNAPSHOTS_DIR="${LOCAL_SNAPSHOTS_DIR:-$VM_REPO/snapshots/vm}"
SYNC_INTERVAL="${SYNC_INTERVAL:-}"

VM_USER="${VM_USER:-}"
VM_IP="${VM_IP:-}"
SSH_KEY="${SSH_KEY:-}"
REMOTE_REPO="${REMOTE_REPO:-}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  local cmd_name="$1"
  command -v "$cmd_name" >/dev/null 2>&1 || die "Missing required command: $cmd_name"
}

require_file() {
  local file_path="$1"
  [[ -f "$file_path" ]] || die "Missing required file: $file_path"
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

load_defaults_from_env() {
  local env_file="$VM_REPO/.env.local"
  [[ -f "$env_file" ]] || return

  if [[ -z "$VM_IP" ]]; then
    VM_IP="$(read_env_key "$env_file" "VM_IP")"
  fi
  if [[ -z "$VM_USER" ]]; then
    VM_USER="$(read_env_key "$env_file" "VM_USER")"
  fi
  if [[ -z "$SSH_KEY" ]]; then
    SSH_KEY="$(read_env_key "$env_file" "SSH_KEY")"
  fi
  if [[ -z "$REMOTE_REPO" ]]; then
    REMOTE_REPO="$(read_env_key "$env_file" "REMOTE_REPO")"
  fi
  if [[ -z "$SYNC_INTERVAL" ]]; then
    SYNC_INTERVAL="$(read_env_key "$env_file" "CLASSSEARCH_POLL_INTERVAL")"
  fi
}

is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

ensure_config() {
  require_cmd ssh
  require_cmd rsync

  load_defaults_from_env

  VM_USER="${VM_USER:-ubuntu}"
  SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
  REMOTE_REPO="${REMOTE_REPO:-~/myucla_tracker}"
  SYNC_INTERVAL="${SYNC_INTERVAL:-15}"
  SSH_KEY="$(expand_home_path "$SSH_KEY")"

  [[ -n "$VM_IP" ]] || die "VM_IP is required (set in .env.local or env var)"
  [[ "$SYNC_INTERVAL" =~ ^[0-9]+$ ]] || die "SYNC_INTERVAL must be an integer (got: $SYNC_INTERVAL)"
  if [[ "$SYNC_INTERVAL" -lt 1 ]]; then
    die "SYNC_INTERVAL must be >= 1 second"
  fi

  if [[ -n "$SSH_KEY" ]]; then
    require_file "$SSH_KEY"
  fi
  mkdir -p "$LOCAL_SNAPSHOTS_DIR"
}

check_remote_rsync() {
  local ssh_target="${VM_USER}@${VM_IP}"
  if [[ -n "$SSH_KEY" ]]; then
    ssh -i "$SSH_KEY" "$ssh_target" "command -v rsync >/dev/null 2>&1" || {
      die "rsync not found on VM. Install with: sudo apt install -y rsync"
    }
  else
    ssh "$ssh_target" "command -v rsync >/dev/null 2>&1" || {
      die "rsync not found on VM. Install with: sudo apt install -y rsync"
    }
  fi
}

sync_once() {
  local ssh_target="${VM_USER}@${VM_IP}"
  local remote_source="${ssh_target}:${REMOTE_REPO}/snapshots/"

  if [[ -n "$SSH_KEY" ]]; then
    rsync -az --delete -e "ssh -i $SSH_KEY" "$remote_source" "${LOCAL_SNAPSHOTS_DIR}/"
  else
    rsync -az --delete "$remote_source" "${LOCAL_SNAPSHOTS_DIR}/"
  fi
}

run_loop() {
  ensure_config
  check_remote_rsync
  echo "$$" >"$PID_FILE"
  trap 'rm -f "$PID_FILE"' EXIT INT TERM

  log "VM snapshot autosync loop started (interval=${SYNC_INTERVAL}s, dest=${LOCAL_SNAPSHOTS_DIR})"
  while true; do
    sync_once
    log "Synced VM snapshots"
    sleep "$SYNC_INTERVAL"
  done
}

start_daemon() {
  ensure_config
  if is_running; then
    log "VM snapshot autosync already running (pid=$(cat "$PID_FILE"))"
    return 0
  fi

  nohup "$0" run >>"$LOG_FILE" 2>&1 &
  local daemon_pid=$!
  sleep 0.2
  if kill -0 "$daemon_pid" >/dev/null 2>&1; then
    echo "$daemon_pid" >"$PID_FILE"
    log "Started VM snapshot autosync (pid=$daemon_pid, interval=${SYNC_INTERVAL}s)"
    log "Log file: $LOG_FILE"
    return 0
  fi

  die "Failed to start VM snapshot autosync"
}

stop_daemon() {
  if ! is_running; then
    rm -f "$PID_FILE"
    log "VM snapshot autosync is not running"
    return 0
  fi

  local pid
  pid="$(cat "$PID_FILE")"
  kill "$pid" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      sleep 0.2
    else
      break
    fi
  done
  if kill -0 "$pid" >/dev/null 2>&1; then
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi
  rm -f "$PID_FILE"
  log "Stopped VM snapshot autosync"
}

status_daemon() {
  if is_running; then
    log "VM snapshot autosync running (pid=$(cat "$PID_FILE"))"
  else
    log "VM snapshot autosync stopped"
  fi
}

case "$ACTION" in
  run)
    run_loop
    ;;
  start)
    start_daemon
    ;;
  stop)
    stop_daemon
    ;;
  restart)
    stop_daemon
    start_daemon
    ;;
  status)
    status_daemon
    ;;
  sync-once)
    ensure_config
    check_remote_rsync
    sync_once
    log "Synced VM snapshots"
    ;;
  *)
    cat <<'USAGE'
Usage: ./sync_vm_snapshots.sh [start|stop|restart|status|run|sync-once]
USAGE
    exit 2
    ;;
esac
