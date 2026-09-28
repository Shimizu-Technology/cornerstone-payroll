#!/usr/bin/env python3
"""Read one Cornerstone financial book using a revocable, book-scoped key."""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


def positive_id(value):
    try:
        result = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a positive integer") from error
    if result <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return result


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=os.getenv("CORNERSTONE_FINANCE_API_URL"),
                        required="CORNERSTONE_FINANCE_API_URL" not in os.environ,
                        help="API v1 base URL, such as https://example.com/api/v1")
    parser.add_argument("--organization-id", type=positive_id,
                        default=os.getenv("CORNERSTONE_FINANCE_ORGANIZATION_ID"),
                        required="CORNERSTONE_FINANCE_ORGANIZATION_ID" not in os.environ)
    parser.add_argument("--book-id", type=positive_id, default=os.getenv("CORNERSTONE_FINANCE_BOOK_ID"),
                        required="CORNERSTONE_FINANCE_BOOK_ID" not in os.environ)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("context", help="Show effective organization and book")
    overview = commands.add_parser("overview", help="Show receivables and payables")
    overview.add_argument("--as-of", help="YYYY-MM-DD for overdue balances")
    invoices = commands.add_parser("invoices", help="List invoices")
    invoices.add_argument("--page", type=positive_id, default=1)
    invoices.add_argument("--per-page", type=positive_id, default=50)
    invoice = commands.add_parser("invoice", help="Show one invoice")
    invoice.add_argument("id", type=positive_id)
    expenses = commands.add_parser("expenses", help="List expenses")
    expenses.add_argument("--page", type=positive_id, default=1)
    expenses.add_argument("--per-page", type=positive_id, default=50)
    expense = commands.add_parser("expense", help="Show one expense")
    expense.add_argument("id", type=positive_id)
    return parser


def main():
    args = build_parser().parse_args()
    token = os.getenv("CORNERSTONE_FINANCE_TOKEN")
    if not token:
        raise ValueError("Set CORNERSTONE_FINANCE_TOKEN to a key from Finance Overview → Agent access")

    base = args.base_url.rstrip("/")
    parsed = urllib.parse.urlparse(base)
    if parsed.scheme != "https" and not (parsed.scheme == "http" and parsed.hostname in ("localhost", "127.0.0.1")):
        raise ValueError("Use HTTPS for the finance API (HTTP is allowed only on localhost)")
    if not parsed.netloc or parsed.username or parsed.password or parsed.query or parsed.fragment or not parsed.path.endswith("/api/v1"):
        raise ValueError("--base-url must end in /api/v1")

    organization_id = positive_id(str(args.organization_id))
    book_id = positive_id(str(args.book_id))
    path = {
        "context": "context", "overview": "overview", "invoices": "invoices",
        "invoice": f"invoices/{args.id}" if args.command == "invoice" else "",
        "expenses": "expenses", "expense": f"expenses/{args.id}" if args.command == "expense" else "",
    }[args.command]
    query = {}
    if args.command == "overview" and args.as_of:
        query["as_of"] = args.as_of
    if args.command in ("invoices", "expenses"):
        query.update(page=args.page, per_page=args.per_page)
    url = f"{base}/finance/{path}"
    if query:
        url += "?" + urllib.parse.urlencode(query)
    request = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "X-Organization-Id": str(organization_id),
        "X-Finance-Book-Id": str(book_id),
        "Accept": "application/json",
    })
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        try:
            detail = json.load(error).get("error", error.reason)
        except (ValueError, AttributeError):
            detail = error.reason
        raise ValueError(f"Finance API returned {error.code}: {detail}") from error
    except urllib.error.URLError as error:
        raise ValueError(f"Cannot reach finance API: {error.reason}") from error
    scope = payload.get("scope")
    if scope != {"organization_id": organization_id, "finance_book_id": book_id}:
        raise ValueError("Finance API returned an unexpected organization or book")
    print(json.dumps(payload, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, argparse.ArgumentTypeError) as error:
        print(f"finance: {error}", file=sys.stderr)
        sys.exit(1)
