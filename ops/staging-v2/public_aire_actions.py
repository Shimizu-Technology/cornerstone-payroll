#!/usr/bin/env python3
"""Read public AIRE Actions evidence without forwarding Payroll's CI token."""

import json
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

BASE = "https://api.github.com/repos/Shimizu-Technology/aire-services/actions/"
MAX_BYTES = 8 * 1024 * 1024


def read(endpoint, query=None):
    url = BASE + endpoint
    if query:
        url += "?" + urlencode(query)
    request = Request(url, headers={"Accept": "application/vnd.github+json",
                                   "User-Agent": "connected-payroll-public-evidence"})
    # Deliberately no GH_TOKEN/GITHUB_TOKEN/config-file lookup or Authorization.
    with urlopen(request, timeout=20) as response:
        body = response.read(MAX_BYTES + 1)
    if len(body) > MAX_BYTES:
        raise ValueError("Public workflow evidence exceeded the bounded response size")
    result = json.loads(body)
    if not isinstance(result, dict):
        raise ValueError("Public workflow evidence is malformed")
    return result


def positive_id(value):
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise ValueError("A positive workflow ID or attempt is required")
    return value


def evidence(arguments):
    if len(arguments) == 2 and arguments[0] == "runs":
        sha = arguments[1]
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise ValueError("A full immutable AIRE SHA is required")
        result = read("workflows/staging-v2.yml/runs", {
            "branch": "staging-v2", "event": "push", "head_sha": sha, "per_page": 100})
        return [{"databaseId": row["id"], "headSha": row["head_sha"], "createdAt": row["created_at"]}
                for row in result["workflow_runs"]]
    if len(arguments) == 2 and arguments[0] == "run":
        return read("runs/" + positive_id(arguments[1]))
    if len(arguments) == 3 and arguments[0] == "jobs":
        run, attempt = map(positive_id, arguments[1:])
        pages = []
        count = None
        seen = 0
        for page in range(1, 101):
            result = read(f"runs/{run}/attempts/{attempt}/jobs", {"per_page": 100, "page": page})
            total = result["total_count"]
            jobs = result["jobs"]
            if type(total) is not int or total < 0 or not isinstance(jobs, list):
                raise ValueError("Public job inventory is malformed")
            if count is None:
                count = total
            if total != count or len(jobs) != min(100, max(count - seen, 0)):
                raise ValueError("Public job inventory changed or is incomplete")
            pages.append(result)
            seen += len(jobs)
            if seen == count:
                return pages
        raise ValueError("Public job inventory exceeded its page limit")
    raise ValueError("Use runs SHA, run ID, or jobs ID ATTEMPT")


def main():
    try:
        print(json.dumps(evidence(sys.argv[1:])))
    except (HTTPError, URLError, TimeoutError, OSError, ValueError, KeyError, TypeError) as error:
        # Responses and environment tokens are never printed.
        print(f"Public AIRE workflow evidence unavailable ({type(error).__name__}); deployment held.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
