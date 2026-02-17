# Oracle VM Runbook (myucla-monitor)

Use this as a quick command reference for operating the monitor on Oracle VM.

## 0) Variables (Mac terminal)

```bash
VM_IP="<VM_IP>"
VM_USER="ubuntu"
SSH_KEY="<SSH_KEY_PATH>"
LOCAL_REPO="<LOCAL_REPO>"
REMOTE_REPO="<REMOTE_REPO>"
```

## 1) Connect to VM

```bash
ssh -i "$SSH_KEY" "$VM_USER@$VM_IP"
```

## 2) Service control (VM terminal)

```bash
sudo systemctl status myucla-monitor --no-pager
sudo systemctl restart myucla-monitor
sudo systemctl stop myucla-monitor
sudo systemctl start myucla-monitor
```

Live logs:

```bash
journalctl -u myucla-monitor -f
```

Recent logs:

```bash
journalctl -u myucla-monitor -n 120 -l --no-pager
```

## 3) Re-auth flow when session expires

### 3.1 Mac terminal: refresh local session

```bash
cd "$LOCAL_REPO"
launchctl bootout gui/$(id -u)/com.myucla.classsearch.monitor 2>/dev/null || true
./venv/bin/python login_save.py
```

Complete Duo in browser, then press Enter in the terminal running `login_save.py`.

### 3.2 Mac terminal: copy new storage.json to VM

```bash
scp -i "$SSH_KEY" "$LOCAL_REPO/storage.json" "$VM_USER@$VM_IP:$REMOTE_REPO/storage.json"
```

### 3.3 VM terminal: restart monitor

```bash
sudo systemctl restart myucla-monitor
journalctl -u myucla-monitor -n 80 -l --no-pager
```

## 4) Sync VM snapshots to local for viewing (Mac terminal)

Install `rsync` once on VM (VM terminal):

```bash
sudo apt update
sudo apt install -y rsync
```

Then sync from Mac:

```bash
rsync -az --delete -e "ssh -i $SSH_KEY" \
  "$VM_USER@$VM_IP:$REMOTE_REPO/snapshots/" \
  "$LOCAL_REPO/snapshots/"
```

Verbose sync:

```bash
rsync -avz --delete -e "ssh -i $SSH_KEY" \
  "$VM_USER@$VM_IP:$REMOTE_REPO/snapshots/" \
  "$LOCAL_REPO/snapshots/"
```

## 5) Quick health checks

VM snapshots:

```bash
ls -lt "$REMOTE_REPO/snapshots" | head
```

Local snapshots:

```bash
ls -lt "$LOCAL_REPO/snapshots" | head
```

Service is healthy when:
- `systemctl status` shows `active (running)`
- logs show fetch/sleep loops without repeated `Detected SSO/login page`
