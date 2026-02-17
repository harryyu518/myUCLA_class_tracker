"""
Shared utilities for UCLA Tracker monitoring scripts.
"""

import os
import re
import glob
import logging
import requests
from datetime import datetime
from pathlib import Path
from typing import Optional
from playwright.sync_api import sync_playwright
import config

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)


def setup_logger(name: str) -> logging.Logger:
    """Get a logger instance with a specific name."""
    return logging.getLogger(name)


class PlaywrightSession:
    """Persistent Playwright browser + context wrapper.
    
    Creates a single browser/context on init and provides `fetch()` to
    navigate the existing page and return content. Keeps the context open
    between calls so cookies/session data persist in memory.
    """

    def __init__(self, storage_state: str | Path):
        storage_state = Path(storage_state)
        if not storage_state.exists():
            raise FileNotFoundError(f"Missing {storage_state}. Run login_save.py first.")
        self.storage_state = str(storage_state)
        self._p = None
        self._browser = None
        self._context = None
        self._page = None

    def start(self) -> None:
        """Start the Playwright session."""
        self._p = sync_playwright().start()
        self._browser = self._p.chromium.launch(headless=config.PLAYWRIGHT_HEADLESS)
        self._context = self._browser.new_context(storage_state=self.storage_state)
        self._page = self._context.new_page()

    def fetch(self, url: str, wait: str = "networkidle", timeout: int | None = None) -> str:
        """Fetch content from a URL and return page HTML."""
        if not self._page:
            raise RuntimeError("Playwright session is not started")
        timeout_ms = config.PLAYWRIGHT_TIMEOUT if timeout is None else timeout
        self._page.goto(url, wait_until=wait, timeout=timeout_ms)
        self._page.wait_for_load_state(wait)
        return self._page.content()

    def close(self) -> None:
        """Close the Playwright session."""
        try:
            if self._context:
                self._context.close()
            if self._browser:
                self._browser.close()
            if self._p:
                self._p.stop()
        except Exception as e:
            logger.warning(f"Error closing Playwright session: {e}")


def is_sso_page(html: str) -> bool:
    """Check if HTML contains SSO/login page indicators."""
    sso_indicators = [
        "Sign In with your UCLA Logon ID",
        "UCLA Single Sign-On",
        "duo_iframe",
        "Duo Mobile",
        "Shibboleth",
    ]
    html_lower = html.lower()
    return any(indicator.lower() in html_lower for indicator in sso_indicators)


def normalize_html(html: str) -> str:
    """Normalize HTML to reduce false positives from timestamps/IDs."""
    # Remove script tags and content
    html = re.sub(r'<script[^>]*>.*?</script>', '', html, flags=re.DOTALL)
    # Remove style tags
    html = re.sub(r'<style[^>]*>.*?</style>', '', html, flags=re.DOTALL)
    # Remove comments
    html = re.sub(r'<!--.*?-->', '', html, flags=re.DOTALL)
    # Treat empty input values as equivalent to missing attribute
    html = re.sub(r"\svalue\s*=\s*(\"\"|'')", "", html, flags=re.IGNORECASE)
    # Normalize whitespace
    html = re.sub(r'\s+', ' ', html)
    return html.strip()


def get_sorted_snapshots(snapshot_dir: Path, pattern: str) -> list[Path]:
    """Return list of snapshot files sorted by timestamp (oldest first)."""
    files = list(snapshot_dir.glob(pattern))
    files.sort()  # Alphabetical sort = chronological sort for YYYYMMDD_HHMMSS format
    return files


def save_snapshot(html: str, snapshot_dir: Path, prefix: str) -> Path:
    """Save HTML with timestamp in filename. Returns path to saved file."""
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    snapshot_dir.mkdir(parents=True, exist_ok=True)
    filename = snapshot_dir / f"{prefix}_{timestamp}.html"
    filename.write_text(html, encoding="utf-8")
    logger.info(f"Saved snapshot: {filename}")
    return filename


def rotate_snapshots(snapshot_dir: Path, pattern: str, keep: int = 5) -> None:
    """Keep only the most recent N snapshot files; delete older ones."""
    files = get_sorted_snapshots(snapshot_dir, pattern)
    if len(files) > keep:
        for old_file in files[:-keep]:
            try:
                old_file.unlink()
                logger.info(f"Deleted old snapshot: {old_file}")
            except Exception as e:
                logger.warning(f"Failed to delete {old_file}: {e}")


def rotate_snapshots_by_patterns(snapshot_dir: Path, patterns: list[str], keep: int = 5) -> None:
    """Keep only the most recent N files across multiple glob patterns."""
    file_map: dict[Path, float] = {}
    for pattern in patterns:
        for file_path in snapshot_dir.glob(pattern):
            try:
                file_map[file_path] = file_path.stat().st_mtime
            except FileNotFoundError:
                # File could disappear between glob and stat
                continue

    files = sorted(file_map.items(), key=lambda item: item[1])  # oldest first
    if len(files) > keep:
        for old_file, _ in files[:-keep]:
            try:
                old_file.unlink()
                logger.info(f"Deleted old snapshot: {old_file}")
            except Exception as e:
                logger.warning(f"Failed to delete {old_file}: {e}")


def compare_snapshots(snapshot_dir: Path, pattern: str) -> bool:
    """Compare the 2 most recent snapshots. Return True if content changed."""
    files = get_sorted_snapshots(snapshot_dir, pattern)
    if len(files) < 2:
        return False  # Not enough files to compare
    
    prev_html = files[-2].read_text(encoding="utf-8")
    curr_html = files[-1].read_text(encoding="utf-8")
    
    prev_norm = normalize_html(prev_html)
    curr_norm = normalize_html(curr_html)
    
    if prev_norm == curr_norm:
        logger.info("No change detected in snapshots")
        return False
    else:
        logger.info("Content changed!")
        return True


def send_pushover_notification(message: str, title: str = "UCLA Tracker") -> bool:
    """Send notification to Pushover. Return True if successful."""
    if not config.PUSHOVER_APP_TOKEN or not config.PUSHOVER_USER_KEY:
        logger.debug("Pushover not configured; skipping notification")
        return False
    
    try:
        response = requests.post(
            config.PUSHOVER_API_URL,
            data={
                "token": config.PUSHOVER_APP_TOKEN,
                "user": config.PUSHOVER_USER_KEY,
                "message": message,
                "title": title,
            },
            timeout=5,
        )
        if response.status_code == 200:
            logger.info(f"Pushover notification sent: {message}")
            return True
        else:
            logger.warning(f"Pushover notification failed with status {response.status_code}")
            return False
    except requests.RequestException as e:
        logger.error(f"Pushover notification error: {e}")
        return False
