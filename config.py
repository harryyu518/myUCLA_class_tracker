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


def _env_int(name: str, default: int) -> int:
    """Read integer from environment, fallback to default if invalid."""
    value = os.getenv(name)
    if value is None:
        return default
    try:
        return int(value)
    except ValueError:
        return default


def _env_bool(name: str, default: bool) -> bool:
    """Read boolean from environment, accepting common truthy values."""
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


PROJECT_ROOT = Path(__file__).resolve().parent
# Load local env files for secrets/runtime overrides.
_load_env_file(PROJECT_ROOT / ".env.local")
_load_env_file(PROJECT_ROOT / ".env")

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
# Paste up to 10 ClassSearch URLs below. Leave empty string ("") for unused slots.
# These are tracked in git so VM can update URLs via `git pull`.
CLASSSEARCH_URL_1 = "https://sa.ucla.edu/ro/ClassSearch/Results?SubjectAreaName=Electrical+and+Computer+Engineering+(EC+ENGR)&CrsCatlgName=149+-+Foundations+of+Computer+Vision&t=26S&sBy=subject&subj=EC+ENGR&catlg=0149&cls_no=%25&undefined=Go&btnIsInIndex=btn_inIndex"
CLASSSEARCH_URL_2 = "https://sa.ucla.edu/ro/ClassSearch/Results?SubjectAreaName=Film+and+Television+(FILM+TV)&CrsCatlgName=4+-+Introduction+to+Art+and+Technique+of+Filmmaking&t=26S&sBy=subject&subj=FILM+TV&catlg=0004&cls_no=%25&undefined=Go&btnIsInIndex=btn_inIndex"
CLASSSEARCH_URL_3 = "https://sa.ucla.edu/ro/ClassSearch/Results?SubjectAreaName=Mathematics+(MATH)&CrsCatlgName=155+-+Mathematical+Imaging&t=26S&sBy=subject&subj=MATH+++&catlg=0155&cls_no=%25&undefined=Go&btnIsInIndex=btn_inIndex"
CLASSSEARCH_URL_4 = "https://sa.ucla.edu/ro/ClassSearch/Results?SubjectAreaName=Statistics+(STATS)&CrsCatlgName=100C+-+Linear+Models&t=261&s_g_cd=%25&sBy=subject&subj=STATS++&catlg=0100C&cls_no=%25&advanced=y&enrollment_status=O&enrollment_status=W&enrollment_status=C&enrollment_status=X&enrollment_status=T&enrollment_status=S&meet_locations=noop&meet_days=M&meet_days=T&meet_days=W&meet_days=R&meet_days=F&meet_days=S&meet_days=U&meet_times=6%3A00+am&meet_times=11%3A59+pm&meet_units=noop&class_career=noop&impacted=noop&enrollment_restrictions=noop&enforced_requisites=noop&individual_studies=noop&btnIsInIndex=btn_inIndex"
CLASSSEARCH_URL_5 = ""
CLASSSEARCH_URL_6 = ""
CLASSSEARCH_URL_7 = ""
CLASSSEARCH_URL_8 = ""
CLASSSEARCH_URL_9 = ""
CLASSSEARCH_URL_10 = ""

_CLASSSEARCH_URL_SLOTS = [
    CLASSSEARCH_URL_1,
    CLASSSEARCH_URL_2,
    CLASSSEARCH_URL_3,
    CLASSSEARCH_URL_4,
    CLASSSEARCH_URL_5,
    CLASSSEARCH_URL_6,
    CLASSSEARCH_URL_7,
    CLASSSEARCH_URL_8,
    CLASSSEARCH_URL_9,
    CLASSSEARCH_URL_10,
]
CLASSSEARCH_URLS = list(dict.fromkeys(url.strip() for url in _CLASSSEARCH_URL_SLOTS if url.strip()))
# Backwards-compatible single URL alias used by login_save.py and older scripts.
CLASSSEARCH_URL = CLASSSEARCH_URLS[0] if CLASSSEARCH_URLS else ""
CLASSSEARCH_POLL_INTERVAL = _env_int("CLASSSEARCH_POLL_INTERVAL", 15)  # seconds
# Match only timestamped ClassSearch snapshots (classsearch_YYYYMMDD_HHMMSS.html)
CLASSSEARCH_SNAPSHOT_PATTERN = "classsearch_[0-9]*.html"
CLASSSEARCH_SSO_SNAPSHOT_PATTERN = "classsearch_sso_*.html"

# ClassPlanner Configuration
CLASSPLANNER_URL = os.getenv("CLASSPLANNER_URL", "https://be.my.ucla.edu/ClassPlanner/ClassPlan.aspx")
CLASSPLANNER_LOGIN_URL = os.getenv("CLASSPLANNER_LOGIN_URL", "https://be.my.ucla.edu/studylist.aspx")
CLASSPLANNER_POLL_INTERVAL = _env_int("CLASSPLANNER_POLL_INTERVAL", 3 * 60)  # 3 minutes
CLASSPLANNER_CSS_SELECTOR = os.getenv("CLASSPLANNER_CSS_SELECTOR", "#ctl00_MainContent_panelGrid")
CLASSPLANNER_SNAPSHOT_PREFIX = "classplanner_changed"
CLASSPLANNER_SNAPSHOT_PATTERN = f"{CLASSPLANNER_SNAPSHOT_PREFIX}_*.html"

# Pushover Notifications (optional, from env vars)
PUSHOVER_API_URL = os.getenv("PUSHOVER_API_URL", "https://api.pushover.net/1/messages.json")
PUSHOVER_APP_TOKEN = os.getenv("PUSHOVER_APP_TOKEN", "")
PUSHOVER_USER_KEY = os.getenv("PUSHOVER_USER_KEY", "")

# Snapshot Retention Policy
MAX_SNAPSHOTS_TO_KEEP = _env_int("MAX_SNAPSHOTS_TO_KEEP", 5)

# Playwright Configuration
PLAYWRIGHT_TIMEOUT = _env_int("PLAYWRIGHT_TIMEOUT", 60000)  # ms
PLAYWRIGHT_HEADLESS = _env_bool("PLAYWRIGHT_HEADLESS", True)
