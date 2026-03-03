# Re-Auth Runbook (Local + VM)

Use this when snapshots start showing `classsearch_sso_*`.

## 1) Local re-auth

Run from local repo:

```bash
cd /Users/harryyu/Projects/myucla_tracker
./scripts/local/reauth_local.sh
```

What it does:

- Validates `.env.local` exists and required keys are present.
- Ensures at least one `CLASSSEARCH_URL_1..CLASSSEARCH_URL_10` is non-empty.
- Runs interactive `login_save.py` and writes `storage.json`.
- Runs local preflight (`is_sso=False`) across all configured ClassSearch URLs.

## 2) Sync auth/config to VM

Run from local repo:

```bash
scp -i ~/.ssh/id_ed25519 storage.json ubuntu@64.181.255.201:~/myucla_tracker/storage.json
scp -i ~/.ssh/id_ed25519 .env.local ubuntu@64.181.255.201:~/myucla_tracker/.env.local
```

## 3) Run VM re-auth script

Run on VM:

```bash
cd ~/myucla_tracker
./scripts/vm/reauth_vm.sh
```

What it does:

- Validates `.env.local` exists and required keys are present.
- Ensures at least one `CLASSSEARCH_URL_1..CLASSSEARCH_URL_10` is non-empty.
- Runs VM preflight (`is_sso=False`) across all configured ClassSearch URLs.
- Restarts `myucla-monitor` and prints recent logs/snapshots.

## 4) Expected healthy state

- Logs show normal fetch/sleep loops without repeated SSO detection.
- New snapshots appear as `classsearch_YYYYMMDD_HHMMSS.html`.
