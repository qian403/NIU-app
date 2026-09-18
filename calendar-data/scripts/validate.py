#!/usr/bin/env python3
"""Validate complete yearly snapshots without network access or school credentials."""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from datetime import date, datetime, timedelta
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[1]
CHINESE_NUMBERS = ('', '一', '二', '三', '四', '五', '六', '七', '八', '九',
                   '十', '十一', '十二', '十三', '十四', '十五', '十六', '十七', '十八')


def load(path: Path):
    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f'{path}: duplicate JSON key {key}')
            result[key] = value
        return result
    return json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=unique_pairs)


def require(condition: bool, message: str):
    if not condition:
        raise ValueError(message)


def check_schema(data, name: str, root: Path):
    schema = load(root / 'schema' / f'{name}.schema.json')
    Draft202012Validator.check_schema(schema)
    errors = sorted(Draft202012Validator(schema, format_checker=FormatChecker()).iter_errors(data),
                    key=lambda error: str(list(error.path)))
    if errors:
        error = errors[0]
        raise ValueError(f'{name}:{"/".join(map(str, error.path))}: {error.message}')


def unique(items, key: str, label: str):
    values = [item[key] for item in items]
    require(len(values) == len(set(values)), f'{label}: duplicate {key}')


def interval(item, label: str):
    start, end = date.fromisoformat(item['startDate']), date.fromisoformat(item['endDate'])
    require(start <= end, f'{label}: endDate precedes startDate')
    return start, end


def check_calendar(data: dict, root: Path = ROOT):
    check_schema(data, 'calendar', root)
    year = data['academicYear']
    first, last = interval(data, str(year))
    require((first, last) == (date(year + 1911, 8, 1), date(year + 1912, 7, 31)),
            f'{year}: expected complete August–July academic year')
    unique(data['sources'], 'id', 'sources')
    sources = {source['id']: source for source in data['sources']}

    def source_check(item, pages=None):
        source = sources.get(item['sourceId'])
        require(source is not None, f'{year}: unknown sourceId {item["sourceId"]}')
        page_numbers = pages if pages is not None else [item['sourcePage']]
        require(len(page_numbers) == len(set(page_numbers)), f'{year}: duplicate source page')
        require(all(1 <= p <= source['pageCount'] for p in page_numbers), f'{year}: invalid source page')

    for source in sources.values():
        require(date.fromisoformat(source['maintainedOn']) <= datetime.fromisoformat(data['updatedAt']).date(),
                f'{year}: source maintenance date after data update')
        for item in source['updateNotes']:
            source_check(dict(item, sourceId=source['id']), item['pages'])
    for item in data['notes']:
        source_check(item, item['pages'])

    require([s['number'] for s in data['semesters']] == [1, 2], f'{year}: expected ordered semesters 1 and 2')
    semesters = {s['number']: s for s in data['semesters']}
    for number, bounds in [(1, (first, date(year + 1912, 1, 31))),
                           (2, (date(year + 1912, 2, 1), last))]:
        semester = semesters[number]
        require(interval(semester, f'{year}/{number}') == bounds, f'{year}/{number}: wrong semester bounds')
        classes_start = date.fromisoformat(semester['classesStartDate'])
        require(bounds[0] <= classes_start <= bounds[1], f'{year}/{number}: classes start outside semester')

    unique(data['events'], 'id', f'{year} events')
    require(data['events'] == sorted(data['events'], key=lambda e: (e['startDate'], e['id'])),
            f'{year}: events must be sorted by startDate, id')
    fingerprints = set()
    for event in data['events']:
        label = event['id']
        start, end = interval(event, label)
        semester = semesters[event['semester']]
        require(label.startswith(f'{year}-{event["semester"]}-'), f'{label}: inconsistent ID prefix')
        require(first <= start <= end <= last, f'{label}: outside academic year')
        # Range events may cross semester boundaries; ownership follows the source page/start date.
        require(date.fromisoformat(semester['startDate']) <= start <= date.fromisoformat(semester['endDate']),
                f'{label}: start date outside owning semester')
        source_check(event)
        fingerprint = (event['title'], event['startDate'], event['endDate'], event['note'])
        require(fingerprint not in fingerprints, f'{label}: duplicate event content')
        fingerprints.add(fingerprint)

    cursor = first
    previous = None
    for week in data['weeks']:
        start, end = interval(week, 'week')
        require(start == cursor, f'{year}: week gap/overlap at {cursor}')
        require((end - start).days <= 6 and end <= last, f'{year}: invalid week length')
        semester = semesters[week['semester']]
        sem_start, sem_end = interval(semester, 'semester')
        require(sem_start <= start <= end <= sem_end, f'{year}: week crosses semester boundary')
        require(start.weekday() == 6 or start == sem_start, f'{year}: week must start Sunday or semester start')
        require(end.weekday() == 5 or end == sem_end, f'{year}: week must end Saturday or semester end')
        source_check(week)
        number, kind = week['number'], week['kind']
        if kind != 'preparation':
            # Published source labels go up to 18; schema v1 accepts explicit labels beyond that too.
            if number < len(CHINESE_NUMBERS):
                expected = {'teaching': '', 'winter': '寒', 'summer': '暑'}[kind] + CHINESE_NUMBERS[number]
                require(week['label'] == expected, f'{year}: label/number mismatch')
            if previous and previous['kind'] == kind:
                continuation = start.weekday() != 6  # Same printed week, split at February 1.
                expected = previous['number'] + (0 if continuation else 1)
                require(number == expected, f'{year}: discontinuous {kind} week number')
            elif kind == 'teaching':
                require(number == 1, f'{year}: teaching block must start at week 1')
        previous = week
        cursor = end + timedelta(days=1)
    require(cursor == last + timedelta(days=1), f'{year}: incomplete week coverage')
    for semester in semesters.values():
        day = semester['classesStartDate']
        match = next((w for w in data['weeks'] if w['startDate'] <= day <= w['endDate']), None)
        require(match and match['kind'] == 'teaching' and match['number'] == 1,
                f'{year}: classes start must fall in first printed teaching week')


def check_history(current: dict, old: dict):
    year = current['academicYear']
    if current == old:
        return
    require(current['revision'] > old['revision'], f'{year}: changed data requires increased revision')
    require(datetime.fromisoformat(current['updatedAt']) > datetime.fromisoformat(old['updatedAt']),
            f'{year}: changed data requires later updatedAt')
    # Catch accidental renumbering of unchanged source entries; semantic edits still need review.
    old_ids = {(e['semester'], e['sourceId'], e['sourceText']): e['id'] for e in old['events']}
    for event in current['events']:
        key = (event['semester'], event['sourceId'], event['sourceText'])
        require(key not in old_ids or old_ids[key] == event['id'], f'{year}: stable event ID changed')


def validate(root: Path = ROOT, base_ref: str | None = None):
    index = load(root / 'index.json')
    check_schema(index, 'index', root)
    unique(index['calendars'], 'academicYear', 'index')
    require([c['academicYear'] for c in index['calendars']] == sorted(c['academicYear'] for c in index['calendars']),
            'index: academic years must be sorted')
    expected_paths = {entry['path'] for entry in index['calendars']}
    actual_paths = {str(p.relative_to(root)) for p in (root / 'years').glob('*.json')}
    require(actual_paths == expected_paths, 'index: missing or unlisted year file')
    repo = root.parent
    old_index = None
    if base_ref:
        # Validate ref independently: a typo must not silently disable history checks.
        subprocess.run(['git', 'rev-parse', '--verify', f'{base_ref}^{{commit}}'], cwd=repo,
                       check=True, stdout=subprocess.DEVNULL)
        old_blob = subprocess.run(['git', 'show', f'{base_ref}:calendar-data/index.json'], cwd=repo,
                                  text=True, capture_output=True)
        if old_blob.returncode == 0:
            old_index = json.loads(old_blob.stdout)
            require({c['academicYear'] for c in old_index['calendars']} <= {c['academicYear'] for c in index['calendars']},
                    'index: do not remove previously published academic years')
    results = []
    for entry in index['calendars']:
        require(entry['path'] == f'years/{entry["academicYear"]}.json', 'index: year/path mismatch')
        path = root / entry['path']
        data = load(path)
        check_calendar(data, root)
        require((data['academicYear'], data['revision']) == (entry['academicYear'], entry['revision']),
                f'{path.name}: index metadata mismatch')
        require(hashlib.sha256(path.read_bytes()).hexdigest() == entry['sha256'], f'{path.name}: index hash mismatch')
        if old_index and any(e['academicYear'] == entry['academicYear'] for e in old_index['calendars']):
            old_blob = subprocess.run(['git', 'show', f'{base_ref}:calendar-data/{entry["path"]}'],
                                      cwd=repo, check=True, text=True, capture_output=True)
            check_history(data, json.loads(old_blob.stdout))
        results.append(f'{data["academicYear"]}: {len(data["events"])} events, {len(data["weeks"])} week segments OK')
    return results


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-ref', help='Existing git commit to check revision increments and stable IDs against')
    args = parser.parse_args()
    try:
        for result in validate(base_ref=args.base_ref):
            print(result)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Calendar validation failed: {error}')
