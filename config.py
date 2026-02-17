"""
Centralized configuration for UCLA Tracker monitoring scripts.
"""

import os
from pathlib import Path


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


# Project paths
PROJECT_ROOT = Path(__file__).resolve().parent
SNAPSHOTS_DIR = PROJECT_ROOT / "snapshots"
CONFIG_DIR = PROJECT_ROOT / "config"
USER_DATA_DIR = PROJECT_ROOT / "pw_user_data"
STORAGE_FILE = PROJECT_ROOT / "storage.json"

# Ensure directories exist
SNAPSHOTS_DIR.mkdir(exist_ok=True)
CONFIG_DIR.mkdir(exist_ok=True)
USER_DATA_DIR.mkdir(exist_ok=True)

# ClassSearch Configuration
CLASSSEARCH_URL = os.getenv(
    "CLASSSEARCH_URL",
    "https://sa.ucla.edu/ro/ClassSearch/Results?SubjectAreaName=Electrical+and+Computer+Engineering+(EC+ENGR)&CrsCatlgName=149+-+Foundations+of+Computer+Vision&t=26S&sBy=subject&subj=EC+ENGR&catlg=0149&cls_no=%25&undefined=Go&btnIsInIndex=btn_inIndex",
)
CLASSSEARCH_POLL_INTERVAL = _env_int("CLASSSEARCH_POLL_INTERVAL", 60)  # seconds
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
PUSHOVER_APP_TOKEN = os.getenv("PUSHOVER_APP_TOKEN", "REDACTED_PUSHOVER_APP_TOKEN")
PUSHOVER_USER_KEY = os.getenv("PUSHOVER_USER_KEY", "REDACTED_PUSHOVER_USER_KEY")

# Snapshot Retention Policy
MAX_SNAPSHOTS_TO_KEEP = _env_int("MAX_SNAPSHOTS_TO_KEEP", 5)

# Playwright Configuration
PLAYWRIGHT_TIMEOUT = _env_int("PLAYWRIGHT_TIMEOUT", 60000)  # ms
PLAYWRIGHT_HEADLESS = _env_bool("PLAYWRIGHT_HEADLESS", True)
