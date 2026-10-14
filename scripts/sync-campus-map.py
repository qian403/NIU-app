#!/usr/bin/env python3
"""Copy the campus map shared by the Android app into the iOS bundle.

The data is generated in windlessme/niu-app-android (mobile/tool/campus_map);
its app-content/campus-map is the copy meant for iOS. Edit the generators
there, never these JSON files.

    python3 scripts/sync-campus-map.py ../niu-app-android          # copy
    python3 scripts/sync-campus-map.py ../niu-app-android --check  # compare only
"""
from pathlib import Path
import filecmp
import json
import shutil
import sys

FILES = ['campus.json', 'jiaose.json', 'gongxue.json', 'shixi.json', 'dianzi.json', 'shihua.json']
KINDS = {'room', 'corridor', 'stairs', 'elevator', 'restroom', 'void', 'terrace'}

root = Path(__file__).resolve().parents[1]
output = root / 'Resources/CampusMap'


def validate(folder: Path) -> None:
    campus = json.loads((folder / 'campus.json').read_text())
    assert campus['attribution'], 'OpenStreetMap attribution is required (ODbL)'
    plans = {b['plan'] for b in campus['buildings'] if b.get('plan')}
    for name in FILES[1:]:
        building = json.loads((folder / name).read_text())
        assert building['id'] == name.removesuffix('.json'), name
        assert building['unit'] == 'm', name
        assert building['floors'], name
        for floor in building['floors']:
            assert floor['outline'], (name, floor['id'])
            for space in floor['spaces']:
                assert space['kind'] in KINDS, (name, floor['id'], space['kind'])
                assert ('rect' in space) != ('polygon' in space), (name, floor['id'], space)
        plans.discard(building['id'])
    assert not plans, f'campus.json links plans that are not bundled: {plans}'


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if len(args) != 1:
        print(__doc__)
        return 2
    android = Path(args[0]).resolve()
    shared = android / 'app-content/campus-map'
    bundled = android / 'mobile/assets/campus_map'
    for name in FILES:
        if not filecmp.cmp(shared / name, bundled / name, shallow=False):
            print(f'{name}: app-content and mobile/assets differ in the Android repo')
            return 1
    validate(shared)

    stale = [n for n in FILES if not (output / n).exists() or not filecmp.cmp(shared / n, output / n, shallow=False)]
    if '--check' in sys.argv:
        for name in stale:
            print(f'{name}: differs from Android')
        print('Campus map matches Android' if not stale else 'Run without --check to update')
        return 1 if stale else 0

    output.mkdir(parents=True, exist_ok=True)
    for name in FILES:
        shutil.copyfile(shared / name, output / name)
    validate(output)
    print(f'Updated {len(stale)} file(s): {", ".join(stale) or "none"}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
