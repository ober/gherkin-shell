#!/usr/bin/env python3
"""Generate bash-compatibility.md from compat test results.

Runs all spec tests and produces a markdown report with per-test pass/fail
for any number of shells. The first shell is always treated as the reference.

Usage: python3 test/gen_compat_report.py [--output FILE] OILS_DIR SHELL1 SHELL2 [SHELL3 ...]
"""

import json
import os
import sys
import datetime

# Import the test runner
sys.path.insert(0, os.path.dirname(__file__))
from run_spec import parse_test_file, run_test, check_result

# Test suites grouped by tier, matching the Makefile
TIERS = {
    'Tier 0 — Core': [
        'smoke', 'pipeline', 'redirect', 'redirect-multi',
        'builtin-eval-source', 'command-sub', 'comments', 'exit-status',
    ],
    'Tier 1 — Expansion & Variables': [
        'here-doc', 'quote', 'word-eval', 'word-split', 'var-sub',
        'var-sub-quote', 'var-num', 'var-op-test', 'var-op-strip',
        'var-op-len', 'assign', 'tilde',
    ],
    'Tier 2 — Builtins & Advanced': [
        'arith', 'glob', 'brace-expansion', 'case_', 'if_', 'loop',
        'for-expr', 'subshell', 'sh-func', 'builtin-echo', 'builtin-printf',
        'builtin-read', 'builtin-cd', 'builtin-set', 'builtin-type',
        'builtin-trap', 'builtin-bracket', 'builtin-misc', 'builtin-process',
        'background', 'command-parsing', 'var-op-bash', 'var-op-slice',
        'assign-extended',
    ],
}

# Friendly descriptions for each test suite
SUITE_DESCRIPTIONS = {
    'smoke': 'Basic shell operations',
    'pipeline': 'Pipe operator and pipelines',
    'redirect': 'I/O redirection (>, <, >>, etc.)',
    'redirect-multi': 'Multiple and complex redirections',
    'builtin-eval-source': 'eval and source/. builtins',
    'command-sub': 'Command substitution $() and ``',
    'comments': 'Shell comments',
    'exit-status': 'Exit status and $?',
    'here-doc': 'Here-documents (<<, <<-, <<< )',
    'quote': 'Quoting (single, double, $\'...\')',
    'word-eval': 'Word evaluation and expansion',
    'word-split': 'IFS word splitting',
    'var-sub': 'Variable substitution ($var, ${var})',
    'var-sub-quote': 'Variable substitution in quoting contexts',
    'var-num': 'Numeric/special variables ($#, $?, $$, etc.)',
    'var-op-test': 'Variable operators (${var:-default}, etc.)',
    'var-op-strip': 'Variable pattern stripping (${var#pat}, etc.)',
    'var-op-len': 'Variable length ${#var}',
    'assign': 'Variable assignment',
    'tilde': 'Tilde expansion (~, ~user)',
    'arith': 'Arithmetic expansion $(( )) and (( ))',
    'glob': 'Filename globbing (*, ?, [...])',
    'brace-expansion': 'Brace expansion ({a,b}, {1..5})',
    'case_': 'case statement',
    'if_': 'if/elif/else statement',
    'loop': 'while, until, for loops',
    'for-expr': 'C-style for ((i=0; ...))',
    'subshell': 'Subshell execution (...)',
    'sh-func': 'Shell functions',
    'builtin-echo': 'echo builtin',
    'builtin-printf': 'printf builtin',
    'builtin-read': 'read builtin',
    'builtin-cd': 'cd builtin',
    'builtin-set': 'set and shopt builtins',
    'builtin-type': 'type/command/which builtins',
    'builtin-trap': 'trap builtin',
    'builtin-bracket': '[[ ]] and [ ] test operators',
    'builtin-misc': 'Misc builtins (true, false, colon, etc.)',
    'builtin-process': 'Process builtins (kill, wait, ulimit, etc.)',
    'background': 'Background jobs (&, wait, jobs)',
    'command-parsing': 'Command parsing edge cases',
    'var-op-bash': 'Bash-specific variable operations',
    'var-op-slice': 'Variable slicing ${var:offset:length}',
    'assign-extended': 'declare/typeset/local/export',
}


def run_suite(spec_file, shells, spec_dir):
    """Run all tests in a spec file. Returns list of per-test results."""
    tests = parse_test_file(spec_file)
    shell_names = [os.path.basename(s) for s in shells]
    results = []

    for idx, test in enumerate(tests):
        test_num = idx + 1
        test_result = {
            'num': test_num,
            'name': test['name'],
            'shells': {},
        }
        bash_actual = None
        for si, (shell, sname) in enumerate(zip(shells, shell_names)):
            stdout, stderr, exit_code = run_test(test, shell, spec_dir)
            is_ref = (si == 0)
            if is_ref:
                bash_actual = (stdout, stderr, exit_code)
            passed, reason = check_result(test, stdout, stderr, exit_code,
                                          is_reference=is_ref,
                                          bash_actual=bash_actual)
            test_result['shells'][sname] = {
                'passed': passed,
                'reason': reason,
            }
        results.append(test_result)
    return results


def main():
    args = sys.argv[1:]
    output_file = None

    if '--output' in args:
        idx = args.index('--output')
        output_file = args[idx + 1]
        args = args[:idx] + args[idx + 2:]

    if len(args) < 3:
        print(f'Usage: {sys.argv[0]} [--output FILE] OILS_DIR SHELL1 SHELL2 [SHELL3 ...]',
              file=sys.stderr)
        sys.exit(1)

    oils_dir = args[0]
    shells = [os.path.abspath(s) for s in args[1:]]
    shell_names = [os.path.basename(s) for s in shells]
    ref_name = shell_names[0]  # first shell is the reference
    spec_dir = oils_dir

    # Collect all results
    all_results = {}  # suite_name -> list of test results
    grand_totals = {sn: [0, 0] for sn in shell_names}  # [pass, total]

    for tier_name, suites in TIERS.items():
        for suite in suites:
            spec_file = os.path.join(oils_dir, 'spec', f'{suite}.test.sh')
            if not os.path.exists(spec_file):
                print(f'  SKIP {suite} (file not found)', file=sys.stderr)
                continue
            print(f'  Running {suite}...', file=sys.stderr)
            results = run_suite(spec_file, shells, spec_dir)
            all_results[suite] = results

            for r in results:
                for sname, info in r['shells'].items():
                    grand_totals[sname][1] += 1
                    if info['passed']:
                        grand_totals[sname][0] += 1

    # Generate markdown
    lines = []

    lines.append('# Shell Compatibility Report')
    lines.append('')
    lines.append(f'Generated: {datetime.date.today().isoformat()}')
    lines.append('')
    lines.append('## Summary')
    lines.append('')
    lines.append('| Shell | Pass | Total | Rate |')
    lines.append('|-------|------|-------|------|')
    for sn in shell_names:
        p, t = grand_totals[sn]
        pct = (p / t * 100) if t else 0
        lines.append(f'| {sn} | {p} | {t} | {pct:.0f}% |')
    lines.append('')

    # Per-tier summary
    lines.append('## Results by Tier')
    lines.append('')

    for tier_name, suites in TIERS.items():
        lines.append(f'### {tier_name}')
        lines.append('')
        # Build header dynamically
        hdr = '| Suite | Description |'
        sep = '|-------|-------------|'
        for sn in shell_names:
            hdr += f' {sn} |'
            sep += '-----|'
        lines.append(hdr)
        lines.append(sep)

        for suite in suites:
            if suite not in all_results:
                continue
            results = all_results[suite]
            desc = SUITE_DESCRIPTIONS.get(suite, '')
            total = len(results)
            row = f'| {suite} | {desc} |'
            for sn in shell_names:
                s_pass = sum(1 for r in results
                             if r['shells'].get(sn, {}).get('passed'))
                s_str = f'{s_pass}/{total}' if s_pass < total else f'**{total}/{total}**'
                row += f' {s_str} |'
            lines.append(row)

        lines.append('')

    # Detailed failures: for each non-reference shell, show tests where
    # reference passes but that shell fails
    for sn in shell_names[1:]:
        lines.append(f'## Failing Tests — {sn}')
        lines.append('')
        lines.append(f'Tests where {sn} fails but {ref_name} passes.')
        lines.append('')

        has_failures = False
        for tier_name, suites in TIERS.items():
            tier_failures = []
            for suite in suites:
                if suite not in all_results:
                    continue
                for r in all_results[suite]:
                    ref_ok = r['shells'].get(ref_name, {}).get('passed', False)
                    sn_ok = r['shells'].get(sn, {}).get('passed', False)
                    if ref_ok and not sn_ok:
                        reason = r['shells'][sn].get('reason', '')
                        tier_failures.append((suite, r['num'], r['name'], reason))

            if tier_failures:
                has_failures = True
                lines.append(f'### {tier_name}')
                lines.append('')
                lines.append('| Suite | # | Test | Reason |')
                lines.append('|-------|---|------|--------|')
                for suite, num, name, reason in tier_failures:
                    reason_short = reason[:80] + '...' if len(reason) > 80 else reason
                    lines.append(f'| {suite} | {num} | {name} | {reason_short} |')
                lines.append('')

        if not has_failures:
            lines.append(f'*None — {sn} passes all tests that {ref_name} passes.*')
            lines.append('')

    # Bonus: tests where non-reference shells pass but reference fails
    for sn in shell_names[1:]:
        lines.append(f'## Bonus: Tests where {sn} passes but {ref_name} fails')
        lines.append('')
        bonus = []
        for suite, results in all_results.items():
            for r in results:
                ref_ok = r['shells'].get(ref_name, {}).get('passed', False)
                sn_ok = r['shells'].get(sn, {}).get('passed', False)
                if sn_ok and not ref_ok:
                    bonus.append((suite, r['num'], r['name']))
        if bonus:
            lines.append('| Suite | # | Test |')
            lines.append('|-------|---|------|')
            for suite, num, name in bonus:
                lines.append(f'| {suite} | {num} | {name} |')
        else:
            lines.append('*None.*')
        lines.append('')

    md = '\n'.join(lines)

    if output_file:
        with open(output_file, 'w') as f:
            f.write(md)
        print(f'Report written to {output_file}', file=sys.stderr)
    else:
        print(md)


if __name__ == '__main__':
    main()
