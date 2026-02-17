#!/usr/bin/env python3
"""
Test Pushover notifications configuration.

Use this script to verify that your Pushover credentials are working.
"""

import logging
import config
import utils

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


def main():
    """Test sending a Pushover notification."""
    logger.info("Testing Pushover notification...")
    logger.info(f"App Token: {config.PUSHOVER_APP_TOKEN[:10]}...")
    logger.info(f"User Key: {config.PUSHOVER_USER_KEY[:10]}...")
    
    success = utils.send_pushover_notification(
        "If you got this, Pushover integration works!",
        title="Pushover Test"
    )
    
    if success:
        print("✓ Pushover test notification sent successfully")
    else:
        print("✗ Failed to send Pushover notification")
        exit(1)


if __name__ == "__main__":
    main()

