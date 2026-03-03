#!/usr/bin/env bash
# ClassPlanner Monitor Launcher
# Runs the ClassPlanner page monitor via the project's virtual environment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
cd "$REPO_ROOT" || exit 1

# Optional: Set Pushover credentials (or export them in your shell environment)
# export PUSHOVER_APP_TOKEN="your_app_token"
# export PUSHOVER_USER_KEY="your_user_key"

exec ./venv/bin/python extract_snippet.py
