"""
Centralized configuration for UCLA Tracker monitoring scripts.
"""

import os
from pathlib import Path


def _load_env_file(env_file: Path) -> None:
    """Load KEY=VALUE pairs from a local .env-style file into os.environ.

    Existing environment variables are not overridden.
    """
    if not env_file.exists():
        return

    for raw_line in env_file.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        if not key:
            continue

        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


def _env_str(name: str) -> str:
    """Read trimmed env string; return empty string when unset."""
    value = os.getenv(name)
    if value is None:
        return ""
    return value.strip()


def _env_required(name: str) -> str:
    """Read required env string; fail fast when unset or blank."""
    value = os.getenv(name)
    if value is None or not value.strip():
        raise ValueError(f"Missing required environment variable: {name}")
    return value.strip()


def _env_int_required(name: str) -> int:
    """Read required env int; fail fast when missing/invalid."""
    value = _env_required(name)
    try:
        return int(value)
    except ValueError as exc:
        raise ValueError(f"Environment variable {name} must be an integer") from exc


def _env_bool_required(name: str) -> bool:
    """Read required env bool; accepts common truthy/falsey strings."""
    value = _env_required(name).lower()
    if value in {"1", "true", "yes", "on"}:
        return True
    if value in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"Environment variable {name} must be a boolean")


PROJECT_ROOT = Path(__file__).resolve().parent
# Load local env files for secrets/runtime overrides.
_load_env_file(PROJECT_ROOT / ".env.local")
_load_env_file(PROJECT_ROOT / ".env")
# Load tracked defaults last (lowest priority) so all tunables live in env files.
_load_env_file(PROJECT_ROOT / ".env.example")

# Project paths
SNAPSHOTS_DIR = PROJECT_ROOT / "snapshots"
CONFIG_DIR = PROJECT_ROOT / "config"
USER_DATA_DIR = PROJECT_ROOT / "pw_user_data"
STORAGE_FILE = PROJECT_ROOT / "storage.json"

# Ensure directories exist
SNAPSHOTS_DIR.mkdir(exist_ok=True)
CONFIG_DIR.mkdir(exist_ok=True)
USER_DATA_DIR.mkdir(exist_ok=True)

# ClassSearch Configuration
# Configure URLs in `.env.local` / `.env` with CLASSSEARCH_URL_1..CLASSSEARCH_URL_10.
_CLASSSEARCH_URL_SLOTS = [_env_str(f"CLASSSEARCH_URL_{index}") for index in range(1, 11)]
CLASSSEARCH_URLS = list(dict.fromkeys(url.strip() for url in _CLASSSEARCH_URL_SLOTS if url.strip()))
# Backwards-compatible single URL alias used by login_save.py and older scripts.
CLASSSEARCH_URL = CLASSSEARCH_URLS[0] if CLASSSEARCH_URLS else ""
CLASSSEARCH_POLL_INTERVAL = _env_int_required("CLASSSEARCH_POLL_INTERVAL")  # seconds
# Match only timestamped ClassSearch snapshots (classsearch_YYYYMMDD_HHMMSS.html)
CLASSSEARCH_SNAPSHOT_PATTERN = "classsearch_[0-9]*.html"
CLASSSEARCH_SSO_SNAPSHOT_PATTERN = "classsearch_sso_*.html"

# ClassPlanner Configuration
CLASSPLANNER_URL = _env_required("CLASSPLANNER_URL")
CLASSPLANNER_LOGIN_URL = _env_required("CLASSPLANNER_LOGIN_URL")
CLASSPLANNER_POLL_INTERVAL = _env_int_required("CLASSPLANNER_POLL_INTERVAL")  # seconds
CLASSPLANNER_CSS_SELECTOR = _env_required("CLASSPLANNER_CSS_SELECTOR")
CLASSPLANNER_SNAPSHOT_PREFIX = "classplanner_changed"
CLASSPLANNER_SNAPSHOT_PATTERN = f"{CLASSPLANNER_SNAPSHOT_PREFIX}_*.html"

# Pushover Notifications (optional, from env vars)
PUSHOVER_API_URL = _env_required("PUSHOVER_API_URL")
PUSHOVER_APP_TOKEN = _env_str("PUSHOVER_APP_TOKEN")
PUSHOVER_USER_KEY = _env_str("PUSHOVER_USER_KEY")

# Snapshot Retention Policy
MAX_SNAPSHOTS_TO_KEEP = _env_int_required("MAX_SNAPSHOTS_TO_KEEP")

# Playwright Configuration
PLAYWRIGHT_TIMEOUT = _env_int_required("PLAYWRIGHT_TIMEOUT")  # ms
PLAYWRIGHT_HEADLESS = _env_bool_required("PLAYWRIGHT_HEADLESS")
