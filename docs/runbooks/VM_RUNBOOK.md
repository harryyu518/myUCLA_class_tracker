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

## 3) Change monitored URLs / poll interval (single-source)

Edit `.env.local` (local repo):

```bash
cd "$LOCAL_REPO"
nano .env.local
```

Set values like:

```bash
CLASSSEARCH_URL_1="<class search url 1>"
CLASSSEARCH_URL_2="<class search url 2>"
CLASSSEARCH_POLL_INTERVAL=5
```

Deploy `.env.local` directly to VM (no git required):

```bash
scp -i "$SSH_KEY" "$LOCAL_REPO/.env.local" "$VM_USER@$VM_IP:$REMOTE_REPO/.env.local"
ssh -i "$SSH_KEY" "$VM_USER@$VM_IP" "sudo systemctl restart myucla-monitor"
ssh -i "$SSH_KEY" "$VM_USER@$VM_IP" "sudo journalctl -u myucla-monitor -n 80 -l --no-pager"
```

## 4) Re-auth flow when session expires

### 4.1 Mac terminal: run local re-auth script

```bash
cd "$LOCAL_REPO"
./scripts/local/reauth_local.sh
```

This validates `.env.local`, runs interactive login, updates `storage.json`, and performs local preflight.

### 4.2 Mac terminal: sync `storage.json` and `.env.local` to VM

```bash
scp -i <SSH_KEY_PATH> storage.json ubuntu@<VM_IP>:~/myucla_tracker/storage.json
scp -i <SSH_KEY_PATH> .env.local ubuntu@<VM_IP>:~/myucla_tracker/.env.local
```

### 4.3 VM terminal: run VM re-auth script

```bash
cd "$REMOTE_REPO"
./scripts/vm/reauth_vm.sh
```

## 5) Sync VM snapshots to local for viewing (Mac terminal)

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

## 6) Quick health checks

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
