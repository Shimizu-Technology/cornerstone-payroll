"""Reject older or incomplete candidate drills before issuing a new certificate."""
import json
import re
import sys


def validate(result, payroll_sha, aire_sha):
    if not all(re.fullmatch(r"[0-9a-f]{40}", sha) for sha in (payroll_sha, aire_sha)):
        raise ValueError("Expected two immutable full commit SHAs")
    required = {
        "schema_version": 1,
        "flow": "accountant-manual-browser-v1",
        "payroll_sha": payroll_sha,
        "aire_sha": aire_sha,
        "browser_passed": True,
        "source_receipt_verified": True,
    }
    if any(type(result.get(key)) is not type(value) or result.get(key) != value for key, value in required.items()):
        raise ValueError("The exact pair lacks completed accountant browser and source receipt acceptance")


if __name__ == "__main__":
    try:
        with open(sys.argv[1], encoding="utf-8") as source:
            result = json.load(source)
        validate(result, sys.argv[2], sys.argv[3])
    except (OSError, ValueError, TypeError, IndexError, AttributeError) as error:
        sys.exit(f"Operator acceptance rejected: {error}")
    print("PASS: exact-pair accountant browser and independent AIRE receipt acceptance")
