#!/usr/bin/env python3
"""
Interactive login script for UCLA authentication.

This script opens a browser window for you to complete the Duo login flow,
then saves your session cookies for use by the monitoring scripts.

Run this whenever your session expires:
    python login_save.py
"""

import logging
import json
import tempfile
import shutil
from playwright.sync_api import sync_playwright

import config

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
handler = logging.StreamHandler()
handler.setFormatter(logging.Formatter("%(asctime)s - %(levelname)s - %(message)s"))
logger.addHandler(handler)

def main():
    """Perform interactive login and save session storage."""
    if not config.CLASSSEARCH_URL:
        raise ValueError("No ClassSearch URL configured. Set CLASSSEARCH_URL_1 in .env.local or .env.")

    logger.info("Starting interactive login session...")
    logger.info(f"Opening browser to: {config.CLASSSEARCH_URL}")
    
    with sync_playwright() as p:
        temp_profile_dir = None
        try:
            # Preferred path: persistent profile for consistency with prior behavior.
            context = p.chromium.launch_persistent_context(
                user_data_dir=str(config.USER_DATA_DIR),
                headless=False
            )
        except Exception as e:
            # Profile lock is common when Chromium left a stale singleton lock.
            # Fallback to a temporary profile so re-auth can still proceed.
            if "ProcessSingleton" not in str(e):
                raise
            logger.warning(
                "Persistent profile is locked. Falling back to temporary browser profile for this login."
            )
            temp_profile_dir = tempfile.mkdtemp(prefix="pw_login_profile_")
            context = p.chromium.launch_persistent_context(
                user_data_dir=temp_profile_dir,
                headless=False
            )

        page = context.new_page()
        page.goto(config.CLASSSEARCH_URL)
        
        logger.info("Browser opened. Please complete login + Duo authentication...")
        logger.info("Press Enter here when you've finished logging in.")
        input()
        
        # Save session state
        context.storage_state(path=str(config.STORAGE_FILE))
        context.close()
        if temp_profile_dir:
            shutil.rmtree(temp_profile_dir, ignore_errors=True)
        logger.info(f"✓ Session saved to {config.STORAGE_FILE}")

        # Provide a quick verification summary so re-auth success is obvious.
        try:
            state = json.loads(config.STORAGE_FILE.read_text(encoding="utf-8"))
            cookies = state.get("cookies", [])
            domains = {c.get("domain", "") for c in cookies}
            logger.info(f"Saved cookies: {len(cookies)}")
            logger.info(f"Contains sa.ucla.edu cookie: {any('sa.ucla.edu' in d for d in domains)}")
            logger.info(f"Contains be.my.ucla.edu cookie: {any('be.my.ucla.edu' in d for d in domains)}")
        except Exception as e:
            logger.warning(f"Could not summarize saved storage state: {e}")


if __name__ == "__main__":
    main()
