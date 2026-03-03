#!/usr/bin/env bash
# ClassSearch Monitor Launcher
# Runs the ClassSearch page monitor via the project's virtual environment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

# Optional: Set Pushover credentials (or export them in your shell environment)
# export PUSHOVER_APP_TOKEN="your_app_token"
# export PUSHOVER_USER_KEY="your_user_key"

exec ./venv/bin/python monitor_classsearch.py
