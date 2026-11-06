"""Public metadata reads preserve exact evidence without cross-repository tokens."""
import io
import json
import unittest
from unittest.mock import patch

import public_aire_actions as reader


class PublicEvidenceTest(unittest.TestCase):
    def response(self, value):
        return io.BytesIO(json.dumps(value).encode())

    def test_public_request_never_forwards_ci_tokens(self):
        with patch.dict('os.environ', {'GH_TOKEN': 'private-root-token', 'GITHUB_TOKEN': 'other-token'}), \
             patch.object(reader, 'urlopen', return_value=self.response({'total_count': 0, 'workflow_runs': []})) as request:
            self.assertEqual(reader.evidence(['runs', 'a' * 40]), [{'total_count': 0, 'workflow_runs': []}])
        sent = request.call_args.args[0]
        self.assertIsNone(sent.get_header('Authorization'))
        self.assertTrue(sent.full_url.startswith(reader.BASE + 'workflows/staging-v2.yml/runs?'))
        self.assertIn('head_sha=' + 'a' * 40, sent.full_url)
        self.assertEqual(request.call_args.kwargs['timeout'], 20)

    def test_exact_runs_inventory_follows_all_pages_without_token(self):
        pages = [{'total_count': 101, 'workflow_runs': [{'id': n+1} for n in range(100)]},
                 {'total_count': 101, 'workflow_runs': [{'id': 101}]}]
        with patch.dict('os.environ', {'GH_TOKEN': 'payroll-only-token'}), \
             patch.object(reader, 'urlopen', side_effect=[self.response(page) for page in pages]) as request:
            self.assertEqual(reader.evidence(['runs', 'a' * 40]), pages)
        self.assertEqual(request.call_count, 2)
        for number, call in enumerate(request.call_args_list, 1):
            self.assertIsNone(call.args[0].get_header('Authorization'))
            self.assertIn('head_sha=' + 'a'*40, call.args[0].full_url)
            self.assertIn('branch=staging-v2', call.args[0].full_url)
            self.assertIn('event=push', call.args[0].full_url)
            self.assertIn('page='+str(number), call.args[0].full_url)

    def test_empty_malformed_or_oversized_run_inventory_is_not_silently_accepted(self):
        for page in [{}, {'total_count':1001,'workflow_runs':[]}, {'total_count':1,'workflow_runs':[]}]:
            with patch.object(reader, 'urlopen', return_value=self.response(page)):
                with self.assertRaises((ValueError,KeyError)):
                    reader.evidence(['runs','a'*40])

    def test_jobs_follow_all_current_attempt_pages(self):
        pages = [{'total_count': 101, 'jobs': [{'id': n} for n in range(100)]},
                 {'total_count': 101, 'jobs': [{'id': 100}]}]
        with patch.object(reader, 'urlopen', side_effect=[self.response(page) for page in pages]) as request:
            self.assertEqual(reader.evidence(['jobs', '12', '3']), pages)
        for call in request.call_args_list:
            self.assertIn('runs/12/attempts/3/jobs?', call.args[0].full_url)
            self.assertIsNone(call.args[0].get_header('Authorization'))

    def test_partial_or_changed_page_is_rejected(self):
        for second in [{'total_count': 101, 'jobs': []}, {'total_count': 102, 'jobs': [{'id': 100}]}]:
            pages = [{'total_count': 101, 'jobs': [{}] * 100}, second]
            with patch.object(reader, 'urlopen', side_effect=[self.response(page) for page in pages]):
                with self.assertRaises(ValueError):
                    reader.evidence(['jobs', '12', '3'])

    def test_invalid_paths_never_make_requests(self):
        for args in [['run', '../secrets'], ['jobs', '12', '0'], ['runs', 'main'], ['other', '12']]:
            with patch.object(reader, 'urlopen') as request:
                with self.assertRaises(ValueError):
                    reader.evidence(args)
                request.assert_not_called()

    def test_response_size_is_bounded(self):
        with patch.object(reader, 'urlopen', return_value=io.BytesIO(b'x' * (reader.MAX_BYTES + 1))):
            with self.assertRaises(ValueError):
                reader.read('runs/12')

    def test_zero_jobs_is_a_complete_page(self):
        page = {'total_count': 0, 'jobs': []}
        with patch.object(reader, 'urlopen', return_value=self.response(page)):
            self.assertEqual(reader.evidence(['jobs', '12', '3']), [page])


if __name__ == '__main__':
    unittest.main()
