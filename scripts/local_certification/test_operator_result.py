import unittest
from verify_operator_result import validate


class OperatorResultTest(unittest.TestCase):
    def setUp(self):
        self.result = {"schema_version": 1, "flow": "accountant-manual-browser-v1",
                       "payroll_sha": "a" * 40, "aire_sha": "b" * 40,
                       "browser_passed": True, "source_receipt_verified": True}

    def test_exact_pair_passes(self):
        validate(self.result, "a" * 40, "b" * 40)

    def test_missing_or_incomplete_acceptance_rejected(self):
        for key in self.result:
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate({k: v for k, v in self.result.items() if k != key}, "a" * 40, "b" * 40)

    def test_false_and_integer_boolean_receipts_rejected(self):
        for value in (False, 1, "true"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate({**self.result, "source_receipt_verified": value}, "a" * 40, "b" * 40)

    def test_other_pair_rejected(self):
        with self.assertRaises(ValueError):
            validate(self.result, "c" * 40, "b" * 40)


if __name__ == "__main__":
    unittest.main()
