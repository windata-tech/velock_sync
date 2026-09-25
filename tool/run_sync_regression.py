#!/usr/bin/env python3
"""Bounded, parallel local regression; no simulator, NAS or user-data writes.

Run: python3 tool/run_sync_regression.py
Evidence: ui_test_results/sync-regression-<timestamp>/summary.json
Live WebDAV and cross-app tests remain separate explicit commands.
"""
import argparse
import concurrent.futures
import datetime
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def evidence_root(root):
    link = root / 'ui_test_results'
    if link.is_symlink():
        link.mkdir(parents=True, exist_ok=True)
        if link.resolve().is_relative_to(root.resolve()):
            raise ValueError('ui_test_results must resolve outside the source tree')
    elif link.exists():
        raise ValueError('Move existing ui_test_results outside the source tree before running')
    else:
        target = root.parent / (root.name + '-artifacts') / 'ui_test_results'
        target.mkdir(parents=True, exist_ok=True)
        link.symlink_to(os.path.relpath(target, root), target_is_directory=True)
    return link


def run_suite(name, command, cwd, output, timeout, deadline=None):
    started = time.monotonic()
    log = output / (name + '.log')
    timed_out = False
    if deadline is not None:
        timeout = min(timeout, max(0, deadline - started))
    with log.open('w') as stream:
        try:
            if timeout <= 0:
                stream.write('Global wall-time budget exhausted before starting suite.\n')
                return dict(name=name, command=command, exit_code=124, elapsed_seconds=0,
                            timed_out=True, log=str(log))
            process = subprocess.Popen(command, cwd=cwd, stdout=stream,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                code = 124
        except OSError as error:
            stream.write(f'Unable to start {name}: {type(error).__name__}\n')
            code = 127
    result = dict(name=name, command=command, exit_code=code,
                  elapsed_seconds=round(time.monotonic() - started, 3),
                  timed_out=timed_out, log=str(log))
    print(f'{"PASS" if code == 0 else "FAIL"} {name}: '
          f'{result["elapsed_seconds"]:.2f}s ({log})', flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--companion-root', type=Path)
    parser.add_argument('--jobs', type=int, choices=range(1, 5), default=3)
    parser.add_argument('--suite-timeout', type=int, default=180)
    parser.add_argument('--wall-budget', type=int, default=180)
    args = parser.parse_args()
    if args.suite_timeout < 1 or args.wall_budget < 1:
        parser.error('timeouts and budgets must be positive seconds')
    root = Path(__file__).resolve().parent.parent
    companion = (args.companion_root or root.parent / 'velock_codex').absolute()
    if not (companion / 'test/sync').is_dir():
        parser.error('Companion test/sync is required; refusing partial green results')
    try:
        artifacts = evidence_root(root)
    except ValueError as error:
        parser.error(str(error))
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    output = artifacts / f'sync-regression-{stamp}-{os.getpid()}'
    output.mkdir()
    suites = [
        ('sync-flutter', ['flutter', 'test', '--no-pub', '--concurrency=2', '--reporter=expanded'], root),
        ('companion-sync', ['flutter', 'test', '--no-pub', '--concurrency=2',
                            'test/sync', '--reporter=expanded'], companion),
        ('verification-tools', [sys.executable, '-m', 'unittest', 'discover',
                                '-s', 'tool/ios_ui_test', '-p', 'test_*.py', '-v'], root),
        ('analyze', ['flutter', 'analyze', '--no-pub'], root),
        ('cross-repo-contract', ['dart', 'run', 'tool/verify_cross_repo_exchange_contract.dart',
                                str(companion)], root),
        ('regression-runner-tests', [sys.executable, 'tool/test_run_sync_regression.py', '-v'], root),
        ('diff-check', ['git', 'diff', '--check'], root),
        ('runner-syntax', ['bash', '-n', 'tool/ios_ui_test/run_cross_app_ui_test.sh'], root),
    ]
    started = time.monotonic()
    deadline = started + args.wall_budget
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
        futures = [executor.submit(run_suite, name, command, cwd, output, args.suite_timeout, deadline)
                   for name, command, cwd in suites]
        results = [future.result() for future in concurrent.futures.as_completed(futures)]
    elapsed = round(time.monotonic() - started, 3)
    within_budget = elapsed <= args.wall_budget
    passed = all(item['exit_code'] == 0 for item in results) and within_budget
    summary = dict(passed=passed, elapsed_seconds=elapsed, wall_budget_seconds=args.wall_budget,
                   within_budget=within_budget, suites=sorted(results, key=lambda item: item['name']),
                   scope='Local tests only; not live NAS, simulator E2E or release performance')
    (output / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
    print(f'Overall {"PASS" if passed else "FAIL"}: {elapsed:.2f}s; '
          f'budget {args.wall_budget}s\n{output / "summary.json"}', flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
