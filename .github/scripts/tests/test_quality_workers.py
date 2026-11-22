import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


class QualityWorkersTest(unittest.TestCase):
    def run_workers(self, fail_shard, hold_shard='none'):
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
    # The held shard keeps running until the test releases it.
    if [ "$shard" = "$HOLD_SHARD" ]; then
      while [ ! -f "$MARKERS/release" ]; do sleep 0.05; done
    fi
    touch "$MARKERS/done-$shard"
    test "$shard" != "$FAIL_SHARD"
    exit $?
  fi
  sleep 0.1
done
exit 23
''')
            worker.chmod(0o755)
            # Log to a file, not pipes: background workers inherit the parent's
            # pipes, so pipe completion would not prove the parent waited.
            log = root / 'parent.log'
            with open(log, 'w') as output:
                parent = subprocess.Popen(['bash', str(script)], cwd=root,
                                          env={**os.environ, 'PATH': f'{commands}:/usr/bin:/bin',
                                               'MARKERS': temp, 'FAIL_SHARD': fail_shard,
                                               'HOLD_SHARD': hold_shard},
                                          stdout=output, stderr=subprocess.STDOUT)
                try:
                    if hold_shard != 'none':
                        deadline = time.monotonic() + 10
                        while not (root / f'done-{fail_shard}').exists():
                            self.assertLess(time.monotonic(), deadline, log.read_text())
                            time.sleep(0.05)
                        time.sleep(0.3)
                        # The failed shard has exited; the parent must still wait.
                        self.assertIsNone(parent.poll(), log.read_text())
                        (root / 'release').touch()
                    returncode = parent.wait(timeout=10)
                finally:
                    if parent.poll() is None:
                        parent.kill()
            self.assertEqual(sorted(p.name for p in root.glob('done-*')),
                             ['done-1', 'done-2', 'done-3'], log.read_text())
            return returncode

    def test_workers_overlap_and_all_complete(self):
        self.assertEqual(self.run_workers('none'), 0)

    def test_worker_failure_fails_job_but_waits_for_other_workers(self):
        self.assertNotEqual(self.run_workers('2', hold_shard='3'), 0)
