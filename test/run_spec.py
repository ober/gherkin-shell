#!/usr/bin/env python3
"""
Simplified spec test runner for Oils test format.
Parses #### test cases, runs them in each shell, compares against ## assertions.
"""

import json
import os
import subprocess
import sys
import tempfile
import re


def parse_test_file(path):
    """Parse a .test.sh file into test cases."""
    tests = []
    current = None

    with open(path, encoding='utf-8', errors='surrogateescape') as f:
        lines = f.readlines()

    i = 0
    while i < len(lines):
        line = lines[i]

        # Test case header
        if line.startswith('#### '):
            if current:
                tests.append(current)
            current = {
                'name': line[5:].strip(),
                'code': [],
                'stdout': None,
                'stdout_json': None,
                'stderr_json': None,
                'status': 0,
                'line_num': i + 1,
            }
            i += 1
            continue

        if current is None:
            i += 1
            continue

        # Metadata lines
        if line.startswith('## '):
            meta = line[3:].strip()

            # stdout: single line
            if meta.startswith('stdout: '):
                current['stdout'] = meta[8:] + '\n'
            # stdout-json: JSON-encoded
            elif meta.startswith('stdout-json: '):
                raw = meta[13:]
                try:
                    current['stdout_json'] = json.loads(raw)
                except json.JSONDecodeError:
                    current['stdout_json'] = raw
            # stderr-json:
            elif meta.startswith('stderr-json: '):
                raw = meta[13:]
                try:
                    current['stderr_json'] = json.loads(raw)
                except json.JSONDecodeError:
                    current['stderr_json'] = raw
            # status:
            elif meta.startswith('status: '):
                current['status'] = int(meta[8:].strip())
            # STDOUT: multi-line
            elif meta == 'STDOUT:':
                stdout_lines = []
                i += 1
                while i < len(lines) and not lines[i].startswith('## '):
                    stdout_lines.append(lines[i])
                    i += 1
                current['stdout'] = ''.join(stdout_lines)
                # i now points at the next ## line; don't increment
                continue
            # STDERR: multi-line (consume but don't check — our runner doesn't test stderr)
            elif meta == 'STDERR:':
                i += 1
                while i < len(lines) and not lines[i].startswith('## '):
                    i += 1
                # i now points at the next ## line; don't increment
                continue
            # N-I (not implemented) markers and other shell-specific annotations
            # Handle OK, OK-2, OK-3, N-I, N-I-2, BUG, BUG-2, etc.
            elif re.match(r'^(N-I|OK|BUG)(-\d+)?\s', meta):
                # Parse bash-specific overrides so gsh (which targets bash compat)
                # uses bash's expected values when they differ from the default
                m = re.match(r'^(N-I|OK|BUG)(-\d+)?\s+([\w/]+)\s+(.*)', meta)
                if m:
                    _kind = m.group(1)
                    shells = m.group(3).split('/')
                    rest = m.group(4).strip()
                    # Use OK-bash overrides (bash alternative acceptable behavior)
                    # and BUG-bash overrides (bash behavior labeled "bug" by oil-shell)
                    # Since gsh targets bash compat, we match bash in both cases
                    if _kind in ('OK', 'BUG') and 'bash' in shells:
                        # Parse the override value
                        if rest.startswith('status: '):
                            current.setdefault('bash_status', int(rest[8:].strip()))
                        elif rest.startswith('stdout: '):
                            current.setdefault('bash_stdout', rest[8:] + '\n')
                        elif rest.startswith('stdout-json: '):
                            raw = rest[13:]
                            try:
                                current.setdefault('bash_stdout', json.loads(raw))
                            except json.JSONDecodeError:
                                current.setdefault('bash_stdout', raw)
                        elif rest == 'STDOUT:':
                            stdout_lines = []
                            i += 1
                            while i < len(lines) and not lines[i].startswith('## '):
                                stdout_lines.append(lines[i])
                                i += 1
                            current.setdefault('bash_stdout', ''.join(stdout_lines))
                            continue
                # Check if this annotation has a STDOUT: or STDERR: block that needs skipping
                if 'STDOUT:' in meta or 'STDERR:' in meta:
                    i += 1
                    while i < len(lines) and not lines[i].startswith('## '):
                        i += 1
                    # i now points at the next ## line; don't increment
                    continue
                # Also handle single-line annotations like "## OK dash status: 2"
                pass  # Skip shell-specific annotations
            # END marker (handled within STDOUT blocks, but skip stray ones)
            elif meta == 'END':
                pass
            # tags, compare_shells, etc.
            elif meta.startswith('tags:') or meta.startswith('compare_shells:') or meta.startswith('oils_'):
                pass
            i += 1
            continue

        # Code line
        current['code'].append(line)
        i += 1

    if current:
        tests.append(current)

    return tests


def run_test(test, shell, spec_dir):
    """Run a test case in a shell, return (stdout, stderr, exit_code)."""
    code = ''.join(test['code'])
    if not code.strip():
        return ('', '', 0)

    # Set up PATH to include spec/bin for helper scripts like argv.py
    env = os.environ.copy()
    # Our own Python 3 spec-bin first, then Oils' spec/bin
    our_spec_bin = os.path.abspath(os.path.join(os.path.dirname(__file__), 'spec-bin'))
    oils_spec_bin = os.path.abspath(os.path.join(spec_dir, 'spec', 'bin'))
    extra_path = ''
    if os.path.isdir(our_spec_bin):
        extra_path = our_spec_bin + ':'
    if os.path.isdir(oils_spec_bin):
        extra_path += oils_spec_bin + ':'
    env['PATH'] = extra_path + env.get('PATH', '')

    with tempfile.TemporaryDirectory() as tmpdir:
        env['TMP'] = tmpdir
        # Create _tmp and _tmp/spec-tmp used by many Oils spec tests
        os.makedirs(os.path.join(tmpdir, '_tmp', 'spec-tmp'), exist_ok=True)
        # Set $SH to the shell being tested (many Oils tests use this)
        env['SH'] = shell
        # Set REPO_ROOT to the Oils vendor directory (for testdata references)
        # spec_dir is already the dirname of the dirname of the spec file,
        # e.g. _vendor/oils — which IS the repo root
        oils_root = os.path.abspath(spec_dir)
        if os.path.isdir(oils_root):
            env['REPO_ROOT'] = oils_root

        try:
            result = subprocess.run(
                [shell, '-c', code],
                capture_output=True,
                timeout=10,
                env=env,
                cwd=tmpdir,
            )
            # Decode without universal newlines to preserve \r
            stdout = result.stdout.decode('utf-8', errors='surrogateescape')
            stderr = result.stderr.decode('utf-8', errors='surrogateescape')
            return (stdout, stderr, result.returncode)
        except subprocess.TimeoutExpired:
            return ('', 'TIMEOUT', -1)
        except Exception as e:
            return ('', str(e), -1)


def check_result(test, stdout, stderr, exit_code, is_reference=False, bash_actual=None):
    """Check if test result matches expectations. Returns (pass, reason).
    For non-reference shells, accept EITHER the default expected values,
    the bash overrides from the test file, OR what bash actually produced."""
    # First check against default expected values
    default_reasons = _check_against(test, stdout, stderr, exit_code,
                                      test['status'],
                                      test.get('stdout') or test.get('stdout_json'),
                                      test.get('stdout_json') is not None)

    if not default_reasons:
        return (True, '')  # Matches default

    # For non-reference shells, also check against bash overrides from test file
    if not is_reference and ('bash_status' in test or 'bash_stdout' in test):
        bash_status = test.get('bash_status', test['status'])
        bash_stdout = test.get('bash_stdout')
        if bash_stdout is None:
            bash_stdout = test.get('stdout') or test.get('stdout_json')
            use_json = test.get('stdout_json') is not None
        else:
            use_json = False
        bash_reasons = _check_against(test, stdout, stderr, exit_code,
                                       bash_status, bash_stdout, use_json)
        if not bash_reasons:
            return (True, '')  # Matches bash alternative from test file

    # For non-reference shells, also accept bash's actual output as valid
    # (if bash also deviates from the spec, matching bash is acceptable)
    if not is_reference and bash_actual is not None:
        bash_stdout_actual, bash_stderr_actual, bash_exit_actual = bash_actual
        if stdout == bash_stdout_actual and exit_code == bash_exit_actual:
            return (True, '')  # Matches what bash actually produced

    return (False, '; '.join(default_reasons))


def _check_against(test, stdout, stderr, exit_code,
                    expected_status, expected_stdout, is_json):
    """Check result against specific expected values. Returns list of reasons."""
    reasons = []

    if exit_code != expected_status:
        reasons.append(f'status: expected {expected_status}, got {exit_code}')

    if expected_stdout is not None:
        if stdout != expected_stdout:
            reasons.append(f'stdout mismatch')

    if test.get('stderr_json') is not None:
        expected_stderr = test['stderr_json']
        if stderr != expected_stderr:
            reasons.append(f'stderr mismatch')

    return reasons


def main():
    if len(sys.argv) < 3:
        print(f'Usage: {sys.argv[0]} spec_file shell1 [shell2 ...]')
        print(f'       {sys.argv[0]} --range N-M spec_file shell1 [shell2 ...]')
        sys.exit(1)

    args = sys.argv[1:]
    test_range = None
    verbose = False

    # Parse options
    while args and args[0].startswith('-'):
        if args[0] == '--range':
            test_range = args[1]
            args = args[2:]
        elif args[0] in ('-v', '--verbose'):
            verbose = True
            args = args[1:]
        else:
            args = args[1:]

    spec_file = args[0]
    shells = args[1:]

    # Find the oils dir for spec/bin
    spec_dir = os.path.dirname(os.path.dirname(spec_file))

    tests = parse_test_file(spec_file)

    # Apply range filter
    if test_range:
        parts = test_range.split('-')
        start = int(parts[0]) - 1
        end = int(parts[1]) if len(parts) > 1 else start + 1
        tests = tests[start:end]

    # Resolve shell paths to absolute
    shells = [os.path.abspath(s) for s in shells]

    # Print header
    shell_names = [os.path.basename(s) for s in shells]
    spec_name = os.path.basename(spec_file).replace('.test.sh', '')
    print(f'--- {spec_name} ---')

    results = {s: {'pass': 0, 'fail': 0, 'total': 0} for s in shell_names}
    failures = []

    for idx, test in enumerate(tests):
        test_num = idx + 1
        bash_actual = None  # Capture bash's actual output for dynamic override
        for si, (shell, sname) in enumerate(zip(shells, shell_names)):
            stdout, stderr, exit_code = run_test(test, shell, spec_dir)
            # First shell is the reference (e.g. bash); others use bash overrides
            is_ref = (si == 0)
            if is_ref:
                bash_actual = (stdout, stderr, exit_code)
            passed, reason = check_result(test, stdout, stderr, exit_code,
                                          is_reference=is_ref,
                                          bash_actual=bash_actual)
            results[sname]['total'] += 1
            if passed:
                results[sname]['pass'] += 1
                if verbose:
                    print(f'  [{sname:>6}] {test_num:3d} {test["name"]:40s} PASS')
            else:
                results[sname]['fail'] += 1
                fail_info = {
                    'test_num': test_num,
                    'name': test['name'],
                    'shell': sname,
                    'reason': reason,
                    'stdout': stdout,
                    'expected_stdout': test.get('stdout') or test.get('stdout_json', ''),
                    'exit_code': exit_code,
                    'expected_status': test['status'],
                }
                failures.append(fail_info)
                if verbose:
                    print(f'  [{sname:>6}] {test_num:3d} {test["name"]:40s} FAIL: {reason}')

    # Print summary
    print()
    for sname in shell_names:
        r = results[sname]
        pct = (r['pass'] / r['total'] * 100) if r['total'] > 0 else 0
        print(f'{sname:>10}: {r["pass"]}/{r["total"]} passed ({pct:.0f}%)')
    print()

    # Print failures for non-bash shells
    gsh_failures = [f for f in failures if f['shell'] != 'bash']
    if gsh_failures:
        print(f'--- {len(gsh_failures)} failures ---')
        for f in gsh_failures:
            print(f'  #{f["test_num"]} {f["name"]}:')
            print(f'    {f["reason"]}')
            if 'stdout mismatch' in f['reason']:
                expected = repr(f['expected_stdout'])
                got = repr(f['stdout'])
                print(f'    expected: {expected}')
                print(f'    got:      {got}')
            if 'status' in f['reason']:
                print(f'    expected status: {f["expected_status"]}, got: {f["exit_code"]}')
            print()

    # Exit with failure count
    total_gsh_fail = sum(1 for f in failures if f['shell'] != 'bash')
    sys.exit(min(total_gsh_fail, 127))


if __name__ == '__main__':
    main()
