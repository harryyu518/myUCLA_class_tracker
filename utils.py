"""
Shared utilities for UCLA Tracker monitoring scripts.
"""

import os
import re
import glob
import shutil
import logging
import requests
from datetime import datetime
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qs, unquote_plus, urlsplit
from playwright.sync_api import sync_playwright
from bs4 import BeautifulSoup
import config

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)
TARGET_URL_MARKER_FILE = ".target_url"


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


def _normalize_course_number(raw_value: str) -> str:
    """Normalize course number strings (e.g. 0143 -> 143)."""
    value = raw_value.strip()
    if re.fullmatch(r"\d+", value):
        return str(int(value))
    return value


def _sanitize_folder_name(folder_name: str) -> str:
    """Sanitize user-facing folder names for filesystem safety."""
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', " ", folder_name)
    name = re.sub(r"\s+", " ", name).strip()
    return name


def get_classsearch_course_label(url: str, fallback_index: int) -> str:
    """Build a folder/display label from ClassSearch URL parameters."""
    query = parse_qs(urlsplit(url).query)

    subject_code = unquote_plus((query.get("subj", [""])[0] or "")).strip()
    catalog_number = unquote_plus((query.get("catlg", [""])[0] or "")).strip()
    catalog_number = _normalize_course_number(catalog_number)

    if not subject_code:
        subject_area = unquote_plus((query.get("SubjectAreaName", [""])[0] or "")).strip()
        match = re.search(r"\(([^)]+)\)", subject_area)
        if match:
            subject_code = match.group(1).strip()
        elif subject_area:
            subject_code = subject_area

    if not catalog_number:
        catalog_name = unquote_plus((query.get("CrsCatlgName", [""])[0] or "")).strip()
        match = re.search(r"\b(\d+[A-Za-z]*)\b", catalog_name)
        if match:
            catalog_number = _normalize_course_number(match.group(1))

    if subject_code and catalog_number:
        label = f"{subject_code} {catalog_number}"
    elif subject_code:
        label = subject_code
    elif catalog_number:
        label = f"Course {catalog_number}"
    else:
        label = f"ClassSearch Target {fallback_index}"

    safe_label = _sanitize_folder_name(label)
    return safe_label or f"ClassSearch Target {fallback_index}"


def build_classsearch_targets(urls: list[str], snapshot_root: Path) -> list[dict[str, str | Path]]:
    """Build target metadata from configured URLs."""
    targets: list[dict[str, str | Path]] = []
    duplicate_counts: dict[str, int] = {}

    for index, raw_url in enumerate(urls, start=1):
        url = raw_url.strip()
        if not url:
            continue
        base_name = get_classsearch_course_label(url, fallback_index=index)
        count = duplicate_counts.get(base_name, 0) + 1
        duplicate_counts[base_name] = count
        target_name = base_name if count == 1 else f"{base_name} ({count})"
        targets.append(
            {
                "name": target_name,
                "url": url,
                "snapshot_dir": snapshot_root / target_name,
            }
        )

    return targets


def sync_classsearch_snapshot_dirs(snapshot_root: Path, targets: list[dict[str, str | Path]]) -> None:
    """Create/update target directories and delete managed folders for removed targets."""
    snapshot_root.mkdir(parents=True, exist_ok=True)
    desired_dirs: set[Path] = set()

    for target in targets:
        target_dir = Path(target["snapshot_dir"])
        target_url = str(target["url"])
        target_dir.mkdir(parents=True, exist_ok=True)
        desired_dirs.add(target_dir.resolve())
        marker_file = target_dir / TARGET_URL_MARKER_FILE
        marker_file.write_text(target_url, encoding="utf-8")

    for child in snapshot_root.iterdir():
        if not child.is_dir():
            continue
        marker_file = child / TARGET_URL_MARKER_FILE
        if not marker_file.exists():
            continue
        if child.resolve() in desired_dirs:
            continue
        shutil.rmtree(child, ignore_errors=True)
        logger.info(f"Deleted snapshot folder for removed URL: {child}")


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


def extract_classsearch_status_map(html: str) -> dict[str, str]:
    """Extract class status text keyed by class row ID from ClassSearch HTML."""
    soup = BeautifulSoup(html, "html.parser")
    statuses: dict[str, str] = {}

    for node in soup.select("div.statusColumn[id$='-status_data']"):
        node_id = node.get("id")
        if not node_id:
            continue
        class_id = node_id.removesuffix("-status_data")
        status_text = re.sub(r"\s+", " ", " ".join(node.stripped_strings)).strip()
        if status_text:
            statuses[class_id] = status_text

    return statuses


def summarize_status_changes(
    prev_statuses: dict[str, str], curr_statuses: dict[str, str], max_items: int = 3
) -> str:
    """Build a short human-readable summary of class status changes."""
    changes: list[str] = []
    all_keys = sorted(set(prev_statuses) | set(curr_statuses))

    for class_id in all_keys:
        prev_value = prev_statuses.get(class_id)
        curr_value = curr_statuses.get(class_id)
        if prev_value == curr_value:
            continue
        if prev_value is None:
            changes.append(f"{class_id}: added -> {curr_value}")
        elif curr_value is None:
            changes.append(f"{class_id}: {prev_value} -> removed")
        else:
            changes.append(f"{class_id}: {prev_value} -> {curr_value}")

    if not changes:
        return ""

    summary = "; ".join(changes[:max_items])
    if len(changes) > max_items:
        summary += f"; +{len(changes) - max_items} more"
    return summary


def compare_status_snapshots(snapshot_dir: Path, pattern: str) -> tuple[bool, str]:
    """Compare status values in the 2 most recent snapshots.

    Returns:
        (changed, summary) where summary describes the status diff.
    """
    files = get_sorted_snapshots(snapshot_dir, pattern)
    if len(files) < 2:
        return False, ""

    prev_html = files[-2].read_text(encoding="utf-8")
    curr_html = files[-1].read_text(encoding="utf-8")
    prev_statuses = extract_classsearch_status_map(prev_html)
    curr_statuses = extract_classsearch_status_map(curr_html)

    if prev_statuses or curr_statuses:
        if prev_statuses == curr_statuses:
            logger.info("No status change detected in snapshots")
            return False, ""

        summary = summarize_status_changes(prev_statuses, curr_statuses)
        logger.info(f"Status changed! {summary}")
        return True, summary

    logger.warning("No status rows found in snapshots; falling back to normalized HTML compare")
    prev_norm = normalize_html(prev_html)
    curr_norm = normalize_html(curr_html)
    if prev_norm == curr_norm:
        logger.info("No change detected in snapshots")
        return False, ""

    logger.info("Content changed!")
    return True, ""


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
