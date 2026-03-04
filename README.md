# myUCLA Class Tracker

Monitor UCLA ClassSearch pages for enrollment/status changes using Playwright, snapshot diffs, and optional Pushover notifications.

## Project Overview

This project:
- Uses a real authenticated browser session (UCLA + Duo) saved in `storage.json`
- Polls one or more ClassSearch URLs on a fixed interval
- Saves timestamped HTML snapshots per class in `snapshots/<CLASS>/`
- Detects status changes and sends optional Pushover alerts
- Detects SSO/session-expired pages and alerts once until session is restored

Optional:
- ClassPlanner monitor (`extract_snippet.py`) with separate polling logic

## How It Works

1. `login_save.py` opens Chromium for interactive UCLA/Duo login.
2. Session state is saved to `storage.json`.
3. `monitor_classsearch.py` loads that storage state and fetches all configured `CLASSSEARCH_URL_*` targets.
4. Each target gets its own snapshot folder (for example `snapshots/EC ENGR 149`).
5. The monitor compares the latest two snapshots per target and notifies when status changes.
6. Snapshot retention is enforced by `MAX_SNAPSHOTS_TO_KEEP` (recommended: `5`).

## Requirements

- macOS or Linux
- Python 3.10+
- `venv`
- Chromium via Playwright
- Optional for VM workflow: `ssh`, `scp`, systemd on the VM

## Setup (Shared)

1. Clone and enter the repo:
   ```bash
   git clone <your-repo-url>
   cd myucla_tracker
   ```
2. Create and activate/install venv deps:
   ```bash
   python3 -m venv venv
   ./venv/bin/pip install -r requirements.txt
   ./venv/bin/python -m playwright install chromium
   ```
3. Create local config:
   ```bash
   cp .env.example .env.local
   ```
4. Edit `.env.local`:
   - Set at least `CLASSSEARCH_URL_1`
   - Set polling/runtime values (Recommended polling interval > 10s)
   - Configure Pushover keys (see section below)

## Pushover Notifications Setup (Real-Time Alerts)

This project can send push notifications to your phone whenever status changes are detected.

1. Create a Pushover account:
   - https://pushover.net/
2. Install the Pushover app on your phone and log in with that account.
3. Get your user key:
   - After login, your **User Key** is shown on the Pushover dashboard.
   - Use that value for `PUSHOVER_USER_KEY`.
4. Create an application/API token:
   - Open: https://pushover.net/apps/build
   - Create a new application (for example `myucla_tracker`).
   - Copy the generated **API Token/Key**.
   - Use that value for `PUSHOVER_APP_TOKEN`.
5. Put both values in `.env.local`:

```env
PUSHOVER_APP_TOKEN=your_app_api_token
PUSHOVER_USER_KEY=your_user_key
PUSHOVER_API_URL=https://api.pushover.net/1/messages.json
```

6. (Optional) Test notifications quickly:
   ```bash
   ./venv/bin/python test_push.py
   ```

## Run Locally (No VM)

### Start Local Monitoring

1. Re-auth and start monitor:
   ```bash
   ./reauth_local.sh
   ```

This script will:
- validate `.env.local`
- open browser for UCLA + Duo login
- save `storage.json`
- run preflight checks
- start/restart local monitor

### Manual Monitor Commands

- Start monitor manually:
  ```bash
  ./run_monitor_classsearch.sh
  ```
- Stop monitor manually:
  ```bash
  pkill -f "monitor_classsearch.py"
  ```

### Optional ClassPlanner Monitor

- Run ClassPlanner monitor:
  ```bash
  ./run_monitor.sh
  ```

## Run With a VM (Local Login + Remote Monitor)

Use this when you want the monitor process running on a Linux VPS, but still complete UCLA login from your local machine browser.

### 1) Prepare VM

On VM (Ubuntu example):

```bash
sudo apt update
sudo apt install -y python3 python3-venv git

git clone <your-repo-url> ~/myucla_tracker
cd ~/myucla_tracker
python3 -m venv venv
./venv/bin/pip install -r requirements.txt
./venv/bin/python -m playwright install chromium
```

### 2) Create systemd service on VM (recommended)

Create `/etc/systemd/system/myucla-monitor.service`:

```ini
[Unit]
Description=myUCLA ClassSearch Monitor
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/myucla_tracker
ExecStart=/home/ubuntu/myucla_tracker/run_monitor_classsearch.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable myucla-monitor
```

### 3) Configure local `.env.local` for VM orchestration

Set these keys:
- `VM_IP`
- `VM_USER` (usually `ubuntu`)
- `SSH_KEY` (for example `~/.ssh/id_ed25519`)
- `REMOTE_REPO` (for example `~/myucla_tracker`)

### 4) Run VM re-auth from local machine

```bash
./reauth_vm.sh
```

This script (from local machine) will:
- stop local monitor to avoid local+VM overlap
- stop VM monitor service
- open browser locally for UCLA + Duo
- save local `storage.json`
- run local preflight check
- upload `storage.json` (and optional `.env.local`) to VM
- run remote preflight and restart VM service

### 5) (Optional, for troubleshooting purposes) Pull VM snapshots to local

```bash
rsync -az --delete -e "ssh -i ~/.ssh/id_ed25519" \
  ubuntu@<VM_IP>:/home/ubuntu/myucla_tracker/snapshots/ \
  /path/to/myucla_tracker/snapshots/
```

### Stop VM monitor

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@<VM_IP> "sudo systemctl stop myucla-monitor"
```

## VPS Hosting Recommendations

If you want a cheap or free VM, these are common options:

- Oracle Cloud Free Tier (includes Always Free resources; this is what many users choose for zero-cost hobby use):
  - https://docs.oracle.com/iaas/Content/FreeTier/freetier.htm
  - https://www.oracle.com/cloud/free/
- Hetzner Cloud (strong price/performance in many regions):
  - https://www.hetzner.com/cloud
- DigitalOcean Droplets (very straightforward UX/docs):
  - https://www.digitalocean.com/pricing/droplets

Choose a region with low latency to you and reliable instance availability.

## Common Issues and Troubleshooting

### 1) `No valid ClassSearch URLs` or env validation failures

- Make sure at least one `CLASSSEARCH_URL_#` is non-empty in `.env.local`.
- Confirm required keys in `.env.example` are present in `.env.local`.

### 2) `Missing required file: ~/.ssh/id_ed25519`

- Your SSH key path is wrong or missing.
- Fix `SSH_KEY` in `.env.local` or create/generate the key.

### 3) `systemctl/journalctl not found`

- Those commands are Linux VM-only.
- `./reauth_vm.sh` should be run locally for orchestration, but remote service management requires systemd on the VM.

### 4) Too many notifications

- Ensure only one monitor is running at a time (local or VM).
- Use `./reauth_local.sh` / `./reauth_vm.sh` to switch modes cleanly.

### 5) Browser login succeeds but monitor still sees SSO

- Re-run:
  ```bash
  ./reauth_local.sh
  ```
- Verify `storage.json` was updated.
- Check latest logs in `monitor_classsearch.err` and monitor output.

## Security and Privacy Notes

- Do not commit `.env.local`, `storage.json`, `pw_user_data/`, or snapshots.
- Treat `storage.json` as sensitive session material.
- If publishing this repo, avoid committing personal IPs/hostnames and private paths.

## Contributing

PRs and issues are welcome.

See [CONTRIBUTING.md](/Users/harryyu/Projects/myucla_tracker/CONTRIBUTING.md) for setup, workflow, and PR guidelines.

## Credits

- Built and maintained by the project author and contributors.
- Powered by Playwright, BeautifulSoup, and Pushover APIs.

## License

This project is licensed under the MIT License. See [LICENSE](/Users/harryyu/Projects/myucla_tracker/LICENSE).
