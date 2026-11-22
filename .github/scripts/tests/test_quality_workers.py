import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class QualityWorkersTest(unittest.TestCase):
    def run_workers(self, fail_shard):
        script = Path(__file__).resolve().parents[1] / 'quality-rspec-workers.sh'
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            commands = root / 'bin'
            commands.mkdir()
            # Test the actual shell orchestration without starting Rails/Postgres.
            for name in ('createdb', 'bundle'):
                path = commands / name
                path.write_text('#!/bin/sh\n'
                                'test "$DATABASE_URL" = "$TEST_DATABASE_URL" || exit 20\n'
                                'case "$DATABASE_URL" in */cornerstone_payroll_ci_[123]_test) ;; *) exit 21;; esac\n'
                                'test -n "$TEST_STORAGE_ROOT" || exit 22\n')
                path.chmod(0o755)
            worker = commands / 'python3'
            worker.write_text('''#!/bin/sh
shard=$4
touch "$MARKERS/start-$shard"
# A sequential implementation deadlocks here and fails the timeout.
for attempt in 1 2 3 4 5; do
  if [ -f "$MARKERS/start-1" ] && [ -f "$MARKERS/start-2" ] && [ -f "$MARKERS/start-3" ]; then
    touch "$MARKERS/done-$shard"
    test "$shard" != "$FAIL_SHARD"
    exit $?
  fi
  sleep 0.1
done
exit 23
''')
            worker.chmod(0o755)
            result = subprocess.run(['bash', str(script)], cwd=root,
                                    env={**os.environ, 'PATH': f'{commands}:/usr/bin:/bin',
                                         'MARKERS': temp, 'FAIL_SHARD': fail_shard},
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(sorted(p.name for p in root.glob('done-*')),
                             ['done-1', 'done-2', 'done-3'], result.stderr)
            return result.returncode

    def test_workers_overlap_and_all_complete(self):
        self.assertEqual(self.run_workers('none'), 0)

    def test_worker_failure_fails_job_but_waits_for_other_workers(self):
        self.assertNotEqual(self.run_workers('2'), 0)
