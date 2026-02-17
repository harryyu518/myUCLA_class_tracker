#!/usr/bin/env python3
"""
Monitor UCLA ClassPlanner page for schedule changes.

- Fetches page every N seconds
- Normalizes dynamic content (timestamps, IDs) to reduce false positives
- Notifies via Pushover when content changes
"""

import time
import re
import logging
from datetime import datetime
from pathlib import Path
from bs4 import BeautifulSoup

import config
import utils

logger = utils.setup_logger(__name__)

# CSS selector for the panel to monitor (focused grid)
CSS_SELECTOR = config.CLASSPLANNER_CSS_SELECTOR


def normalize_text(soup: BeautifulSoup) -> str:
    """Normalize text by removing dynamic elements (IDs, timestamps, etc)."""
    # Remove known dynamic label elements
    dynamic_ids = [
        "ctl00_MainContent_planNameLabel",
        "ctl00_MainContent_planStatusLabel",
        "ctl00_MainContent_planNotesLabel",
    ]
    for element_id in dynamic_ids:
        el = soup.find(id=element_id)
        if el:
            el.decompose()

    # Remove plan name elements by class
    for el in soup.select('.classPlanner_PlanName'):
        el.decompose()

    # Remove text nodes mentioning "Study List refreshed"
    for txt in soup.find_all(string=re.compile(r"Study List refreshed at", re.I)):
        parent = txt.parent
        if parent:
            parent.decompose()

    # Get text with normalization
    text = soup.get_text(" ", strip=True)
    # Normalize whitespace
    text = " ".join(text.split())

    # Strip common dynamic patterns: times and dates like 10/26/25
    text = re.sub(r"\b\d{1,2}:\d{2}:\d{2}\s*(AM|PM)?\b", "", text)
    text = re.sub(r"\b\d{1,2}/\d{1,2}/\d{2,4}\b", "", text)
    # Remove leftover repeated whitespace
    text = re.sub(r"\s{2,}", " ", text).strip()
    return text


def fetch_page_text() -> tuple[str, str]:
    """
    Fetch the ClassPlanner page and extract the monitored panel content.
    
    Returns:
        (normalized_text, html_content) - normalized text and HTML of the panel/page
    """
    if not config.STORAGE_FILE.exists():
        raise FileNotFoundError(f"Missing {config.STORAGE_FILE}. Run login_save.py first.")

    session = utils.PlaywrightSession(config.STORAGE_FILE)
    try:
        session.start()
        html = session.fetch(config.CLASSPLANNER_URL, timeout=config.PLAYWRIGHT_TIMEOUT)
    finally:
        session.close()

    soup = BeautifulSoup(html, "html.parser")
    node = soup.select_one(CSS_SELECTOR)
    
    if not node:
        # Fallback: normalize entire page if selector doesn't match
        logger.warning(f"CSS selector '{CSS_SELECTOR}' not found; using entire page")
        normalized = normalize_text(soup)
        return normalized, html

    normalized = normalize_text(node)
    return normalized, str(node)


def monitor_classplanner():
    """Main monitoring loop for ClassPlanner page."""
    logger.info("Starting ClassPlanner monitor...")
    logger.info(f"URL: {config.CLASSPLANNER_URL}")
    logger.info(f"CSS Selector: {CSS_SELECTOR}")
    logger.info(f"Poll interval: {config.CLASSPLANNER_POLL_INTERVAL}s")
    
    try:
        prev_text, _ = fetch_page_text()
        logger.info("Initial page fetch complete; monitoring for changes")
    except Exception as e:
        logger.error(f"Failed to fetch initial page: {e}")
        return

    try:
        while True:
            time.sleep(config.CLASSPLANNER_POLL_INTERVAL)
            
            try:
                curr_text, curr_html = fetch_page_text()
                
                if curr_text != prev_text:
                    message = f"ClassPlanner content changed at {datetime.now().strftime('%H:%M:%S')}"
                    logger.warning(message)
                    utils.send_pushover_notification(message, title="ClassPlanner Monitor")
                    
                    # Save snapshot of the change
                    utils.save_snapshot(
                        curr_html,
                        config.SNAPSHOTS_DIR,
                        config.CLASSPLANNER_SNAPSHOT_PREFIX,
                    )
                    utils.rotate_snapshots(
                        config.SNAPSHOTS_DIR,
                        config.CLASSPLANNER_SNAPSHOT_PATTERN,
                        config.MAX_SNAPSHOTS_TO_KEEP,
                    )
                    prev_text = curr_text
                else:
                    logger.debug(f"No change at {datetime.now().strftime('%H:%M:%S')}")
                    
            except Exception as e:
                logger.error(f"Error during fetch: {e}")
                utils.send_pushover_notification(
                    f"ClassPlanner monitor error: {e}",
                    title="ClassPlanner Monitor Error"
                )

    except KeyboardInterrupt:
        logger.info("Monitor interrupted by user")


if __name__ == "__main__":
    monitor_classplanner()
