# Re-Auth Runbook (SSO Recovery + Prevention)

Use this when snapshots start showing `classsearch_sso_*` (logged out loop).

## Normal re-auth flow

1. Run:
   ```bash
   ./venv/bin/python login_save.py
   ```
2. Complete UCLA login + Duo in browser.
3. Return to the same terminal and press `Enter`.

## Required verification

After pressing Enter, confirm output includes:

- `Session saved to .../storage.json`
- `Contains sa.ucla.edu cookie: True`

Optional timestamp check:

```bash
stat -f "%Sm %N" -t "%Y-%m-%d %H:%M:%S" storage.json
```

## Restart monitor after re-auth

```bash
launchctl kickstart -k gui/$(id -u)/com.myucla.classsearch.monitor
```

## Stop all active monitor/auth processes

Run this before re-auth if things are stuck:

```bash
launchctl bootout gui/$(id -u)/com.myucla.classsearch.monitor 2>/dev/null || true
pkill -f "monitor_classsearch.py" 2>/dev/null || true
pkill -f "Python login_save.py" 2>/dev/null || true
pkill -f "playwright/driver/node .*run-driver" 2>/dev/null || true
pkill -f "Google Chrome for Testing.*myucla_tracker/pw_user_data" 2>/dev/null || true
pkill -f "pw_login_profile_" 2>/dev/null || true
rm -f pw_user_data/SingletonLock pw_user_data/SingletonCookie pw_user_data/SingletonSocket pw_user_data/RunningChromeVersion
```

## If re-auth does not stick

### Case 1: Profile lock error (`ProcessSingleton` / `SingletonLock`)

Stop stale processes, then retry:

```bash
pkill -f "Python login_save.py"
pkill -f "monitor_classsearch.py"
./venv/bin/python login_save.py
```

### Case 2: You logged in browser but still SSO snapshots

Most common cause: Enter was not pressed in terminal, so `storage.json` was never saved.

Re-run:

```bash
./venv/bin/python login_save.py
```

Complete login, then press Enter in terminal.

## Full clean reset (if needed)

```bash
launchctl bootout gui/$(id -u)/com.myucla.classsearch.monitor 2>/dev/null || true
pkill -f "monitor_classsearch.py" 2>/dev/null || true
pkill -f "Python login_save.py" 2>/dev/null || true
pkill -f "playwright/driver/node .*run-driver" 2>/dev/null || true
rm -f pw_user_data/SingletonLock pw_user_data/SingletonCookie pw_user_data/SingletonSocket pw_user_data/RunningChromeVersion
./venv/bin/python login_save.py
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/com.myucla.classsearch.monitor.plist"
launchctl kickstart -k gui/$(id -u)/com.myucla.classsearch.monitor
```

## Expected healthy state

- New snapshots appear as `classsearch_YYYYMMDD_HHMMSS.html`
- `classsearch_sso_*.html` no longer keeps growing indefinitely (now capped by rotation)
