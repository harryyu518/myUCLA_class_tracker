# UCLA Tracker

Automated UCLA page monitoring with Playwright, snapshot diffing, and Pushover alerts.

## What this project does

This project continuously fetches a configured UCLA page, saves timestamped HTML snapshots, compares recent snapshots, and sends a Pushover notification when content changes.

It is designed to survive normal session expiration by:

- Persisting login state in `storage.json`
- Detecting SSO/login pages
- Letting you re-auth with `reauth_local.sh` (local) and `reauth_vm.sh` (VM)
- Reloading Playwright context from updated storage state

## Quick start

1. Create venv and install dependencies:
   ```bash
   python3 -m venv venv
   ./venv/bin/pip install -r requirements.txt
   ```
2. Create local runtime config (recommended):
   ```bash
   cp .env.example .env.local
   ```
   Fill `.env.local` (ClassSearch URLs, poll intervals, optional Pushover secrets).
3. Log in once and save auth state:
   ```bash
   ./venv/bin/python login_save.py
   ```
4. Run monitor:
   ```bash
   ./venv/bin/python monitor_classsearch.py
   ```

## Re-auth scripts

- Local machine (refresh auth + validate env + preflight all targets):
  ```bash
  ./reauth_local.sh
  ```
- `reauth_local.sh` now also ensures local ClassSearch monitoring is running after successful re-auth.
- VM workflow from local terminal (login + sync + remote preflight/restart):
  ```bash
  ./reauth_vm.sh
  ```

Concurrency guard:
- `reauth_local.sh` stops the VM monitor service first (when VM connection values are configured).
- `reauth_vm.sh` stops local monitor processes first, then stops the VM service before re-auth, and restarts it at the end.

Both require `.env.local` and fail fast if required keys are missing (poll intervals, runtime settings, or all ClassSearch URL slots empty).
Operational runbooks live in `docs/runbooks/`.

## How it works (detailed)

### 1) Playwright authentication model

- `login_save.py` launches a **persistent Chromium context** using `pw_user_data/`.
- You complete UCLA login + Duo interactively in a real browser window.
- On Enter, it writes `context.storage_state(...)` to `storage.json`.
- `storage.json` contains cookies/local storage that later runs can reuse.

Important behavior:
- `login_save.py` opens `config.CLASSSEARCH_URL`, so auth is captured for the same domain/path family the monitor uses.

### 2) Monitor runtime loop

`monitor_classsearch.py` runs a loop:

1. Start `utils.PlaywrightSession(config.STORAGE_FILE)`
2. Fetch URL with `page.goto(..., wait_until="networkidle")`
3. Classify response:
   - If SSO/login page: treat as expired session
   - Else: treat as normal monitored content
4. Save snapshot
5. Rotate snapshots
6. Compare last two snapshots
7. Notify on change
8. Sleep and repeat

### 3) SSO/session expiration handling

SSO detection uses keyword matching (`utils.is_sso_page`), including terms like:

- `UCLA Single Sign-On`
- `Sign In with your UCLA Logon ID`
- `duo_iframe`

When SSO is detected:

- A one-time “session expired” Pushover alert is sent
- `classsearch_sso_YYYYMMDD_HHMMSS.html` is saved for debugging
- The Playwright context is closed and recreated from `storage.json` so a fresh `login_save.py` can be picked up without a full process restart

When non-SSO content returns again:

- “session restored” notification is sent once
- Normal monitoring continues

### 4) Snapshot and diff pipeline

Normal snapshots are saved as:

- `snapshots/classsearch_YYYYMMDD_HHMMSS.html`

The compare/rotation pattern is configured as:

- `CLASSSEARCH_SNAPSHOT_PATTERN = "classsearch_[0-9]*.html"`

This intentionally excludes:

- `classsearch_sso_*.html`
- `classsearch_saved.html`

So SSO/debug files do not trigger normal change alerts.

Before compare, HTML is normalized by:

- Removing `<script>...</script>`
- Removing `<style>...</style>`
- Removing `<!-- comments -->`
- Collapsing whitespace

Then the two most recent normalized snapshots are compared. If different, a Pushover “changed” alert is sent.

### 5) Snapshot retention

`MAX_SNAPSHOTS_TO_KEEP` controls retention for normal snapshots (default `5`).

Rotation is executed after each normal save, so only the latest N matching files are kept.

Note:
- SSO snapshots are diagnostic and are not part of normal rotation unless you add separate cleanup for `classsearch_sso_*`.

## Configuration

Runtime values are read from `.env.local` / `.env` (loaded by `config.py`).

Most important settings:

- `CLASSSEARCH_URL_1..CLASSSEARCH_URL_10`: ClassSearch pages to monitor
- `CLASSSEARCH_POLL_INTERVAL`: ClassSearch loop sleep interval in seconds
- `CLASSPLANNER_POLL_INTERVAL`: ClassPlanner poll interval in seconds
- `MAX_SNAPSHOTS_TO_KEEP`: normal snapshot retention count
- `PLAYWRIGHT_TIMEOUT`: navigation timeout
- `PLAYWRIGHT_HEADLESS`: run headless or headed
- `PUSHOVER_*`: notification configuration

`CLASSSEARCH_URL` remains as a backwards-compatible alias to the first non-empty configured URL.

### Secret handling

- Do not store secrets in committed files.
- Use `.env.local` (gitignored) for local tokens/keys.
- Keep `storage.json`, `pw_user_data/`, and `snapshots/` out of git.

## Running modes

### Manual

```bash
./venv/bin/python monitor_classsearch.py
```

### LaunchAgent (macOS)

Install/load:

```bash
cp config/com.myucla.classsearch.monitor.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.myucla.classsearch.monitor.plist
```

Restart after config/code changes:

```bash
launchctl kickstart -k gui/$(id -u)/com.myucla.classsearch.monitor
```

## Project structure

```text
myucla_tracker/
├── config.py                      # Central config (URLs, intervals, auth, retention)
├── utils.py                       # Playwright wrapper, diff/rotation, notifications
├── monitor_classsearch.py         # Main monitoring loop
├── login_save.py                  # Interactive auth + storage.json refresh
├── extract_snippet.py             # ClassPlanner monitor (separate flow)
├── test_push.py                   # Pushover verification script
├── reauth_local.sh                # Local re-auth script
├── reauth_vm.sh                   # VM re-auth orchestrator (run from local or VM)
├── run_monitor.sh                 # ClassPlanner monitor launcher
├── run_monitor_classsearch.sh     # ClassSearch monitor launcher
├── docs/runbooks/                 # Operational runbooks
│   ├── REAUTH_RUNBOOK.md
│   └── VM_RUNBOOK.md
├── snapshots/                     # Saved HTML snapshots
├── pw_user_data/                  # Persistent browser profile data
├── storage.json                   # Playwright storage state
├── config/                        # LaunchAgent plist files
└── requirements.txt               # Python dependencies
```

## Troubleshooting

### `ModuleNotFoundError: No module named 'playwright'`

You are likely using system Python. Use:

```bash
./venv/bin/python login_save.py
```

### Stuck on SSO snapshots

1. Re-auth:
   ```bash
   ./reauth_local.sh
   ```
2. If running via LaunchAgent, restart:
   ```bash
   launchctl kickstart -k gui/$(id -u)/com.myucla.classsearch.monitor
   ```

### Push alerts when page “looks the same”

Possible causes:

- Real HTML changed in non-visual attributes
- Dynamic framework attributes (e.g. Angular runtime attrs) changed
- Session/redirect transitions produced structurally different HTML

Inspect with direct diff between recent snapshots.

## Notes

- This project does not bypass UCLA auth; it automates a browser session you authenticate manually.
- Treat `storage.json` and `pw_user_data/` as sensitive session artifacts.
