#!/usr/bin/env python3
"""Check a shared-profile validator against the app's built-in component IDs.

Usage: python3 Tools/profile-check/check-fix-ids.py /path/to/profiles.py
Reads source as data; does not execute the validator or access the network.
"""
import ast
from pathlib import Path
import re
import sys


def app_fix_ids(root):
    source = (root / 'Sources/NokcanduCore/CompatibilityFixes.swift').read_text()
    cases = source.split('public enum CompatibilityFix:', 1)[1].split('public var id:', 1)[0]
    result = {'cinematic'}
    for line in cases.splitlines():
        if line.strip().startswith('case '):
            for case in line.strip()[5:].split(','):
                match = re.fullmatch(r'\s*(\w+)(?:\s*=\s*"([a-z0-9-]+)")?\s*', case)
                if not match:
                    raise ValueError('Unrecognized component declaration: ' + case)
                result.add(match.group(2) or match.group(1))
    return result


def validator_fix_ids(path):
    for node in ast.parse(Path(path).read_text()).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'FIXES' for t in node.targets):
            return set(ast.literal_eval(node.value))
    raise ValueError('Validator has no literal FIXES allowlist')


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[2]
    expected, actual = app_fix_ids(root), validator_fix_ids(sys.argv[1])
    if expected != actual:
        print('Missing:', sorted(expected - actual), 'Unexpected:', sorted(actual - expected))
        raise SystemExit(1)
    print(f'All {len(expected)} built-in profile fix IDs match.')
