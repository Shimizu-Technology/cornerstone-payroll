#!/usr/bin/env python3
"""Partition the default RSpec inventory and fail closed on lost/duplicate examples."""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import subprocess
import os
from urllib.parse import urlparse


def partition(files, count, timings):
    groups = [[] for _ in range(count)]
    loads = [0.0] * count
    # First cold run uses file size. Subsequent runs use measured example seconds.
    known = [value for value in timings.values() if value > 0]
    fallback = sum(known) / len(known) if known else None
    weights = {file: timings.get(file, fallback or Path(file).stat().st_size) for file in files}
    for file in sorted(files, key=lambda file: (-weights[file], file)):
        target = min(range(count), key=lambda index: (loads[index], index))
        groups[target].append(file)
        loads[target] += weights[file]
    return groups


def ids(report):
    return [example['id'] for example in report['examples']]


def verify(directory, count):
    reports = [json.loads((directory / f'shard-{n}.json').read_text()) for n in range(1, count + 1)]
    inventories = [json.loads((directory / f'inventory-{n}.json').read_text()) for n in range(1, count + 1)]
    expected = Counter(ids(inventories[0]))
    if not expected or any(value != 1 for value in expected.values()):
        raise ValueError('Empty or duplicate full-suite inventory')
    if any(Counter(ids(report)) != expected for report in inventories):
        raise ValueError('Shards did not collect identical full-suite inventories')
    actual = Counter(example for report in reports for example in ids(report))
    if actual != expected:
        raise ValueError(f'Coverage differs: missing={expected - actual}, extra={actual - expected}')
    if any(report['summary']['failure_count'] or report['summary'].get('errors_outside_of_examples_count', 0) for report in reports):
        raise ValueError('RSpec reported failures')
    timings = defaultdict(float)
    for report in reports:
        for example in report['examples']:
            timings[example['file_path'].removeprefix('./')] += example['run_time']
    (directory / 'timings.json').write_text(json.dumps(timings, indent=2) + '\n')
    pending = sum(report['summary']['pending_count'] for report in reports)
    print(f'Coverage verified: {len(expected)} unique examples, each assigned exactly once; {pending} pending (including existing pooler-only examples).')


def run(shard, count, directory, timing_path):
    # Never allow Rails' implicit DATABASE_URL to override the disposable test DB.
    for name in ('DATABASE_URL', 'TEST_DATABASE_URL'):
        url = urlparse(os.environ.get(name, ''))
        if url.hostname != '127.0.0.1' or url.path != f'/cornerstone_payroll_ci_{shard}_test':
            raise ValueError(f'{name} must name this shard\'s disposable loopback database')
    if os.environ.get('RAILS_ENV') != 'test':
        raise ValueError('RAILS_ENV must be test')
    directory.mkdir(parents=True, exist_ok=True)
    inventory = directory / f'inventory-{shard}.json'
    subprocess.run(['bundle', 'exec', 'rspec', '--dry-run', '--format', 'json', '--out', str(inventory)], check=True)
    collected = json.loads(inventory.read_text())
    files = sorted({example['file_path'].removeprefix('./') for example in collected['examples']})
    timings = json.loads(timing_path.read_text()) if timing_path.exists() else {}
    groups = partition(files, count, timings)
    if not groups[shard - 1]:
        raise ValueError('Empty shard; lower shard count')
    (directory / f'files-{shard}.json').write_text(json.dumps(groups[shard - 1], indent=2) + '\n')
    subprocess.run(['bundle', 'exec', 'rspec', *groups[shard - 1], '--format', 'progress', '--format', 'json', '--out', str(directory / f'shard-{shard}.json')], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['run', 'verify'])
    parser.add_argument('--shard', type=int)
    parser.add_argument('--count', type=int, default=3)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--timings', type=Path, default=Path('../tmp/quality-timings/timings.json'))
    args = parser.parse_args()
    if args.count < 1 or (args.mode == 'run' and (args.shard is None or not 1 <= args.shard <= args.count)):
        parser.error('Invalid shard/count')
    if args.mode == 'run':
        run(args.shard, args.count, args.directory, args.timings)
    else:
        verify(args.directory, args.count)
