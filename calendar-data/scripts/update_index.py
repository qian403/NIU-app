#!/usr/bin/env python3
"""Rebuild index hashes after explicitly updating each changed year's revision/updatedAt."""
import hashlib
import json
from validate import ROOT, check_calendar, load


def main():
    entries = []
    for path in sorted((ROOT / 'years').glob('*.json')):
        data = load(path)
        check_calendar(data)
        if path.name != f'{data["academicYear"]}.json':
            raise ValueError(f'{path.name}: year/filename mismatch')
        entries.append(dict(academicYear=data['academicYear'], revision=data['revision'],
                            path=f'years/{path.name}', sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
    index = dict(schemaVersion=1, calendars=sorted(entries, key=lambda e: e['academicYear']))
    (ROOT / 'index.json').write_text(json.dumps(index, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'Updated index for {len(entries)} academic years')


if __name__ == '__main__':
    main()
