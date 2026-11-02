#!/usr/bin/env python3
"""Exercise the trusted shared-profile normalizer without posting a profile."""
import runpy
import sys
from pathlib import Path

checks = runpy.run_path(str(Path(__file__).with_name('check-fix-ids.py')))
root = Path(__file__).resolve().parents[2]
ids = checks['app_fix_ids'](root)
validator = runpy.run_path(sys.argv[1], run_name='profile_validator_test')
for fix in sorted(ids):
    profile = {'schema': 2, 'title': 'Component test', 'source': 'folder',
               'match': {'exeName': 'UA_source.exe' if fix == 'openua-display' else 'allods2.exe'},
               'rating': 'playable', 'fixes': [fix]}
    normalized, errors = validator['normalize'](profile)
    assert not errors, (fix, errors)
    assert normalized['fixes'] == [fix]
profile['fixes'] = ['unknown-library-download']
assert validator['normalize'](profile)[1]
print(f'{len(ids)} component profiles normalized; unknown fix rejected. No profile posted.')

for frame in (1, 2, 3):
    profile = {'schema': 2, 'title': 'Native IPX test', 'source': 'folder', 'match': {'exeName': 'allods2.exe'},
               'rating': 'works', 'fixes': ['ipx-networking', 'native-ipx-networking'], 'nativeIPXFrame': frame}
    normalized, errors = validator['normalize'](profile)
    assert not errors and normalized['nativeIPXFrame'] == frame
for invalid in (0, 4, True, '3', [3]):
    profile['nativeIPXFrame'] = invalid
    assert validator['normalize'](profile)[1]
profile['nativeIPXFrame'] = 3
profile['fixes'] = ['ipx-networking']
assert validator['normalize'](profile)[1]
profile['fixes'] = ['native-ipx-networking']
profile['schema'] = 1
assert validator['normalize'](profile)[1]
print('Native IPX frame choices round-trip; invalid values, missing component and old schema rejected.')
