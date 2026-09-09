#!/usr/bin/env python3
"""Inject non-secret release settings; never edit the tracked source plist."""
import os
import plistlib
import re
import sys
from urllib.parse import urlsplit


def settings(require_distribution=False):
    values = {}
    for environment, key in [("WEVAULT_VERSION", "CFBundleShortVersionString"),
                             ("WEVAULT_BUILD", "CFBundleVersion"),
                             ("WEVAULT_FEEDBACK_EMAIL", "WeVaultFeedbackEmail"),
                             ("WEVAULT_UPDATE_FEED_URL", "WeVaultUpdateFeedURL")]:
        value = os.environ.get(environment, "")
        if require_distribution and not value:
            raise ValueError(f"Missing required release setting: {environment}")
        if not value:
            continue
        if environment == "WEVAULT_BUILD" and (not re.fullmatch(r"[1-9][0-9]{0,8}", value)):
            raise ValueError("WEVAULT_BUILD must be a positive integer")
        if environment == "WEVAULT_VERSION" and not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
            raise ValueError("WEVAULT_VERSION must be major.minor.patch")
        if environment == "WEVAULT_FEEDBACK_EMAIL" and not re.fullmatch(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+", value):
            raise ValueError("Invalid feedback email")
        if environment == "WEVAULT_UPDATE_FEED_URL":
            url = urlsplit(value)
            if url.scheme != "https" or not url.hostname or url.username or url.password or url.fragment:
                raise ValueError("Update feed must be an HTTPS URL without credentials or fragment")
        values[key] = value
    return values


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--preflight"]:
            settings(require_distribution=True)
        else:
            target = sys.argv[1]
            with open(target, "rb") as source:
                plist = plistlib.load(source)
            plist.update(settings())
            with open(target, "wb") as destination:
                plistlib.dump(plist, destination)
    except (ValueError, IndexError) as error:
        sys.exit(str(error))
