#!/usr/bin/env python3
"""
Monitor UCLA ClassSearch page for enrollment changes.

- Fetches page every N seconds
- Saves snapshots with timestamps in the snapshots/ directory
- Keeps only the 5 most recent snapshots
- Compares class status values and notifies via Pushover on status change
- Detects and alerts on SSO/login page (session expiration)
"""

import time
import logging
from datetime import datetime
from pathlib import Path

import config
import utils

logger = utils.setup_logger(__name__)


def monitor_classsearch():
    """Main monitoring loop for ClassSearch page."""
    logger.info("Starting ClassSearch monitor...")
    logger.info(f"URL: {config.CLASSSEARCH_URL}")
    logger.info(f"Poll interval: {config.CLASSSEARCH_POLL_INTERVAL}s")
    
    session = None
    sso_alert_sent = False
    iteration = 0
    
    try:
        session = utils.PlaywrightSession(config.STORAGE_FILE)
        session.start()
        logger.info("Playwright session started")
    except (FileNotFoundError, Exception) as e:
        logger.error(f"Failed to start Playwright session: {e}")
        return

    try:
        while True:
            logger.info(f"[Fetch {iteration}] Fetching ClassSearch page...")
            try:
                html = session.fetch(config.CLASSSEARCH_URL)

                # Detect SSO / login page (session expired)
                if utils.is_sso_page(html):
                    logger.warning("Detected SSO/login page — session likely expired")
                    if not sso_alert_sent:
                        utils.send_pushover_notification(
                            "ClassSearch monitor: session expired — please re-login interactively.",
                            title="ClassSearch Monitor"
                        )
                        sso_alert_sent = True
                    utils.save_snapshot(html, config.SNAPSHOTS_DIR, "classsearch_sso")
                    utils.rotate_snapshots_by_patterns(
                        config.SNAPSHOTS_DIR,
                        [
                            config.CLASSSEARCH_SNAPSHOT_PATTERN,
                            config.CLASSSEARCH_SSO_SNAPSHOT_PATTERN,
                        ],
                        config.MAX_SNAPSHOTS_TO_KEEP,
                    )
                    # Reload context from storage.json so a fresh login_save.py
                    # is picked up without requiring a manual monitor restart.
                    try:
                        session.close()
                    except Exception:
                        pass
                    session = utils.PlaywrightSession(config.STORAGE_FILE)
                    session.start()
                    logger.info("Reloaded Playwright session from storage state")
                    logger.info(f"Waiting {config.CLASSSEARCH_POLL_INTERVAL}s before retrying...")
                    time.sleep(config.CLASSSEARCH_POLL_INTERVAL)
                    iteration += 1
                    continue

                # Normal page: reset any SSO alert flag
                if sso_alert_sent:
                    utils.send_pushover_notification(
                        "ClassSearch monitor: session restored — fetched page successfully.",
                        title="ClassSearch Monitor"
                    )
                    sso_alert_sent = False

                # Save snapshot and prune old files
                utils.save_snapshot(html, config.SNAPSHOTS_DIR, "classsearch")
                utils.rotate_snapshots_by_patterns(
                    config.SNAPSHOTS_DIR, 
                    [
                        config.CLASSSEARCH_SNAPSHOT_PATTERN,
                        config.CLASSSEARCH_SSO_SNAPSHOT_PATTERN,
                    ],
                    config.MAX_SNAPSHOTS_TO_KEEP
                )

                # Compare with previous and notify on status change
                status_changed, status_summary = utils.compare_status_snapshots(
                    config.SNAPSHOTS_DIR,
                    config.CLASSSEARCH_SNAPSHOT_PATTERN
                )
                if status_changed:
                    timestamp = datetime.now().strftime('%H:%M:%S')
                    if status_summary:
                        message = f"ClassSearch status changed at {timestamp}: {status_summary}"
                    else:
                        message = f"ClassSearch status changed at {timestamp}"
                    message = message[:1024]
                    utils.send_pushover_notification(message, title="ClassSearch Monitor")

            except Exception as e:
                logger.error(f"Error during fetch: {e}")
                try:
                    logger.info("Attempting to restart Playwright session...")
                    session.close()
                    session = utils.PlaywrightSession(config.STORAGE_FILE)
                    session.start()
                except Exception as e2:
                    logger.error(f"Failed to restart session: {e2}")
                    utils.send_pushover_notification(
                        f"ClassSearch monitor error: {e2}",
                        title="ClassSearch Monitor Error"
                    )

            logger.info(f"Sleeping {config.CLASSSEARCH_POLL_INTERVAL}s until next fetch...")
            time.sleep(config.CLASSSEARCH_POLL_INTERVAL)
            iteration += 1

    except KeyboardInterrupt:
        logger.info("Monitor interrupted by user")
    finally:
        if session:
            try:
                session.close()
                logger.info("Playwright session closed")
            except Exception as e:
                logger.error(f"Error closing session: {e}")


if __name__ == "__main__":
    monitor_classsearch()
