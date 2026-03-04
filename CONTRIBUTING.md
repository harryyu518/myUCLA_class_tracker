# Contributing

Thanks for your interest in improving this project.

## Before You Start

- Open an issue first for non-trivial changes (new features, behavior changes, major refactors).
- Keep security/privacy in mind:
  - Do not commit `.env.local`, `storage.json`, `pw_user_data/`, or `snapshots/`.
  - Do not include personal IP addresses, hostnames, or private tokens in docs.

## Local Development Setup

```bash
python3 -m venv venv
./venv/bin/pip install -r requirements.txt
./venv/bin/python -m playwright install chromium
cp .env.example .env.local
```

Fill `.env.local` with your own values before running scripts.

## Useful Commands

- Interactive login and save auth state:
  ```bash
  ./venv/bin/python login_save.py
  ```
- Run ClassSearch monitor:
  ```bash
  ./venv/bin/python monitor_classsearch.py
  ```
- Local re-auth flow:
  ```bash
  ./reauth_local.sh
  ```
- VM re-auth orchestration:
  ```bash
  ./reauth_vm.sh
  ```

## Pull Request Guidelines

- Keep PRs focused and small.
- Include clear reproduction and verification steps in the PR description.
- Update docs when behavior or commands change.
- Prefer backward-compatible changes unless there is a clear reason not to.

## Code Style

- Follow existing code style and script conventions.
- Keep shell scripts POSIX/Bash-friendly and fail-fast (`set -euo pipefail`).
- Avoid introducing unnecessary dependencies.

## Reporting Bugs

Please include:
- What you expected
- What happened
- Exact command you ran
- Relevant log lines from `monitor_classsearch.err` or script output
- Your OS/environment (local and/or VM)
