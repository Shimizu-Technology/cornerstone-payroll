import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('quality_rspec', Path(__file__).parents[1] / 'quality_rspec.py')
quality = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quality)


class QualityRspecTest(unittest.TestCase):
    def test_partition_is_exhaustive_deterministic_and_balanced(self):
        files = ['a', 'b', 'c', 'd', 'e', 'new']
        timings = dict(zip(files[:-1], [8, 7, 6, 5, 4]))
        groups = quality.partition(files, 3, timings)
        self.assertEqual(sorted(sum(groups, [])), sorted(files))
        self.assertEqual(groups, quality.partition(list(reversed(files)), 3, timings))
        self.assertEqual(sorted(sum(timings.get(f, 6) for f in g) for g in groups), [12, 12, 12])

    def test_cold_partition_includes_every_file_once(self):
        with tempfile.TemporaryDirectory() as temp:
            files = []
            for n in range(7):
                path = Path(temp) / str(n)
                path.write_text('x' * (n + 1))
                files.append(str(path))
            self.assertEqual(sorted(sum(quality.partition(files, 3, {}), [])), sorted(files))

    def reports(self, directory, actual):
        expected = [{'id': f'spec/a_spec.rb[1:{n}]'} for n in range(1, 4)]
        for n in range(1, 4):
            (directory / f'inventory-{n}.json').write_text(json.dumps({'examples': expected}))
            examples = [{'id': item, 'file_path': './spec/a_spec.rb', 'run_time': 1} for item in actual[n - 1]]
            (directory / f'shard-{n}.json').write_text(json.dumps({'examples': examples, 'summary': {'failure_count': 0, 'pending_count': 0}}))

    def test_coverage_accepts_exact_partition_and_records_timings(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.reports(directory, [[f'spec/a_spec.rb[1:{n}]'] for n in range(1, 4)])
            quality.verify(directory, 3)
            self.assertEqual(json.loads((directory / 'timings.json').read_text()), {'spec/a_spec.rb': 3})

    def test_coverage_rejects_missing_duplicate_inventory_drift_and_failures(self):
        for problem in ('missing', 'duplicate', 'inventory', 'failure'):
            with self.subTest(problem=problem), tempfile.TemporaryDirectory() as temp:
                directory = Path(temp)
                actual = [[f'spec/a_spec.rb[1:{n}]'] for n in range(1, 4)]
                if problem == 'missing':
                    actual[1] = []
                if problem == 'duplicate':
                    actual[1] = actual[0]
                self.reports(directory, actual)
                if problem == 'inventory':
                    (directory / 'inventory-2.json').write_text('{"examples": []}')
                if problem == 'failure':
                    path = directory / 'shard-1.json'
                    report = json.loads(path.read_text())
                    report['summary']['failure_count'] = 1
                    path.write_text(json.dumps(report))
                with self.assertRaises(ValueError):
                    quality.verify(directory, 3)

    def test_unsafe_database_fails_before_invoking_rails(self):
        with patch.dict('os.environ', {'RAILS_ENV': 'test', 'DATABASE_URL': 'postgres://127.0.0.1/api_development', 'TEST_DATABASE_URL': 'postgres://127.0.0.1/cornerstone_payroll_ci_1'}), patch.object(quality.subprocess, 'run') as command:
            with self.assertRaises(ValueError):
                quality.run(1, 3, Path('/unused'), Path('/unused'))
            command.assert_not_called()


if __name__ == '__main__':
    unittest.main()
