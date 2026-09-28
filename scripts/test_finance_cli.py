import contextlib
import io
import json
import os
import sys
import unittest
from unittest import mock

import finance_cli


ENV = {
    "CORNERSTONE_FINANCE_TOKEN": "cfin_test_secret",
    "CORNERSTONE_FINANCE_API_URL": "https://finance.example.test/api/v1",
    "CORNERSTONE_FINANCE_ORGANIZATION_ID": "7",
    "CORNERSTONE_FINANCE_BOOK_ID": "11",
}


class FinanceCliTest(unittest.TestCase):
    def run_cli(self, payload, command=None):
        opener = mock.Mock()
        opener.open.return_value = contextlib.closing(io.BytesIO(json.dumps(payload).encode()))
        output = io.StringIO()
        with mock.patch.dict(os.environ, ENV, clear=True), mock.patch.object(sys, "argv", ["finance_cli.py", *(command or ["context"])]), \
                mock.patch("finance_cli.urllib.request.build_opener", return_value=opener), contextlib.redirect_stdout(output):
            finance_cli.main()
        return opener.open.call_args, output.getvalue()

    def test_sends_explicit_book_scope_and_accepts_only_matching_response(self):
        args, output = self.run_cli({"scope": {"organization_id": 7, "finance_book_id": 11}, "book": {"name": "Shimizu"}})
        request = args.args[0]
        self.assertEqual(request.full_url, "https://finance.example.test/api/v1/finance/context")
        self.assertEqual(request.headers["Authorization"], "Bearer cfin_test_secret")
        self.assertEqual(request.headers["X-organization-id"], "7")
        self.assertEqual(request.headers["X-finance-book-id"], "11")
        self.assertEqual(json.loads(output)["book"]["name"], "Shimizu")

        with self.assertRaisesRegex(ValueError, "unexpected organization or book"):
            self.run_cli({"scope": {"organization_id": 7, "finance_book_id": 12}})

    def test_rejects_insecure_remote_url_before_sending_key(self):
        with mock.patch.dict(os.environ, {**ENV, "CORNERSTONE_FINANCE_API_URL": "http://finance.example.test/api/v1"}, clear=True), \
                mock.patch.object(sys, "argv", ["finance_cli.py", "context"]), \
                mock.patch("finance_cli.urllib.request.build_opener") as opener:
            with self.assertRaisesRegex(ValueError, "Use HTTPS"):
                finance_cli.main()
            opener.assert_not_called()

    def test_draft_writes_send_json_idempotency_and_version(self):
        response = {"scope": {"organization_id": 7, "finance_book_id": 11}, "invoice": {"id": 42, "lock_version": 1}}
        invoice_file = mock.mock_open(read_data=json.dumps({"notes": "Agent draft"}))
        with mock.patch("builtins.open", invoice_file):
            args, _ = self.run_cli(response, ["draft-create", "invoice.json", "--idempotency-key", "draft-create-001"])
        request = args.args[0]
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(request.headers["Idempotency-key"], "draft-create-001")
        self.assertEqual(json.loads(request.data), {"invoice": {"notes": "Agent draft"}})

        with mock.patch("builtins.open", invoice_file):
            args, _ = self.run_cli(response, ["draft-update", "42", "changes.json", "--version", "0",
                                              "--idempotency-key", "draft-update-001"])
        request = args.args[0]
        self.assertEqual(request.get_method(), "PATCH")
        self.assertEqual(request.headers["X-invoice-version"], "0")
        self.assertEqual(request.full_url, "https://finance.example.test/api/v1/finance/invoices/42")

    def test_new_key_needs_no_api_credentials(self):
        output = io.StringIO()
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(sys, "argv", ["finance_cli.py", "new-key"]), \
                contextlib.redirect_stdout(output):
            finance_cli.main()
        self.assertRegex(output.getvalue().strip(), r"^[a-f0-9]{32}$")


if __name__ == "__main__":
    unittest.main()
