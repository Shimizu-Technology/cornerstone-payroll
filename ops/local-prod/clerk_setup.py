"""Configure the "Cornerstone Payroll Local" Clerk development instance.

Backend API only (never the dashboard), and only a development instance:
the script refuses anything else before writing. It sets the allowed origins
to the local HTTPS hosts and makes sure the staff login exists. It writes
non-secret ids to the output file; keys and passwords are never printed.

usage: clerk_setup.py OUTPUT.json ORIGIN [ORIGIN ...]
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.clerk.com/v1"
STAFF_EMAIL = "payroll.admin+clerk_test@example.com"


def load_keys(path):
    keys = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            name, sep, value = line.strip().partition("=")
            if sep:
                keys[name] = value.strip().strip("'\"")
    return keys


def call(secret, method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(f"{API}{path}", data=data, method=method)
    request.add_header("Authorization", f"Bearer {secret}")
    request.add_header("Content-Type", "application/json")
    # Clerk's edge refuses urllib's default agent.
    request.add_header("User-Agent", "cornerstone-local-prod/1")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            text = response.read().decode()
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode()[:300]
        sys.exit(f"Clerk {method} {path} failed: {error.code} {detail}")


def main():
    output, origins = sys.argv[1], sys.argv[2:]
    secret = load_keys(os.environ["CLERK_ENV_FILE"]).get("CLERK_SECRET_KEY", "")
    if not secret.startswith("sk_test_"):
        sys.exit("Refusing: CLERK_SECRET_KEY is not a development (sk_test_) key")

    instance = call(secret, "GET", "/instance")
    if instance.get("environment_type") != "development":
        sys.exit("Refusing: the Clerk instance is not a development instance")

    if sorted(instance.get("allowed_origins") or []) != sorted(origins):
        call(secret, "PATCH", "/instance", {"allowed_origins": origins})

    query = urllib.parse.urlencode({"email_address": STAFF_EMAIL})
    users = call(secret, "GET", f"/users?{query}")
    password = os.environ["LP_STAFF_PASSWORD"]
    if users:
        user = users[0]
        call(secret, "PATCH", f"/users/{user['id']}", {"password": password, "skip_password_checks": True})
    else:
        user = call(secret, "POST", "/users", {
            "email_address": [STAFF_EMAIL],
            "first_name": "Payroll",
            "last_name": "Admin",
            "password": password,
            "skip_password_checks": True,
        })

    with open(output, "w", encoding="utf-8") as handle:
        json.dump({"instance_id": instance["id"], "staff_user_id": user["id"], "staff_email": STAFF_EMAIL}, handle, indent=2)
    os.chmod(output, 0o600)


if __name__ == "__main__":
    main()
