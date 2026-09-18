import copy
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from validate import ROOT, check_calendar, check_history, load, validate


class CalendarTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.y114 = load(ROOT / 'years/114.json')
        cls.y115 = load(ROOT / 'years/115.json')

    def event(self, year, title, semester=1):
        return next(e for e in year['events'] if e['title'] == title and e['semester'] == semester)

    def rejects(self, mutate, message):
        data = copy.deepcopy(self.y115)
        mutate(data)
        with self.assertRaisesRegex(ValueError, message):
            check_calendar(data)

    def test_complete_published_snapshots(self):
        results = validate()
        index = load(ROOT / 'index.json')
        self.assertEqual(len(results), len(index['calendars']))
        self.assertTrue({114, 115} <= {e['academicYear'] for e in index['calendars']})

    def test_cross_year_final_exam_preserves_inclusive_end(self):
        for data, start, end in [(self.y114, '2025-12-22', '2026-01-11'), (self.y115, '2026-12-21', '2027-01-10')]:
            e = self.event(data, '期末考試')
            self.assertEqual((e['startDate'], e['endDate']), (start, end))
            self.assertEqual(e['note'], '評量時間自行安排')

    def test_warning_parenthetical_end_is_not_lost(self):
        e = self.event(self.y115, '期中預警開始')
        self.assertEqual((e['startDate'], e['endDate']), ('2026-09-21', '2026-11-20'))
        e = self.event(self.y114, '期中成績預警開始', 2)
        self.assertEqual(e['endDate'], '2026-05-08')
        self.assertEqual(e['category'], 'academic')

    def test_compound_dates_split_without_merging_holidays(self):
        for title, start, end in [('除夕前一日','2027-02-04','2027-02-04'), ('除夕','2027-02-05','2027-02-05'), ('春節','2027-02-06','2027-02-10')]:
            e = self.event(self.y115, title, 2)
            self.assertEqual((e['startDate'], e['endDate']), (start, end))

    def test_makeup_and_suspension_qualifiers_preserved(self):
        self.assertEqual(self.event(self.y115, '國慶日')['note'], '適逢假日')
        self.assertEqual(self.event(self.y115, '國慶日補假')['startDate'], '2026-10-09')
        e = self.event(self.y115, '校際活動日', 2)
        self.assertEqual(e['startDate'], '2027-04-07')
        self.assertEqual(e['note'], '停課；授課教師自行擇期補課')

    def test_source_week_can_differ_from_exam_period(self):
        # PDF calls Sunday Jan 10 寒一 while its exam range still includes that day.
        w = next(w for w in self.y115['weeks'] if w['startDate'] == '2027-01-10')
        self.assertEqual(w['label'], '寒一')
        self.assertEqual(self.event(self.y115, '寒假開始')['startDate'], '2027-01-11')
        self.assertEqual(self.event(self.y115, '期末考試')['endDate'], '2027-01-10')

    def test_same_printed_week_split_at_semester_boundary(self):
        records = [w for w in self.y115['weeks'] if w['label'] == '寒四']
        self.assertEqual([(w['startDate'],w['endDate'],w['semester']) for w in records],
                         [('2027-01-31','2027-01-31',1),('2027-02-01','2027-02-06',2)])

    def test_invalid_calendar_date(self):
        self.rejects(lambda d: d['events'][0].update(startDate='2026-02-30'), 'not a .date.')

    def test_end_before_start(self):
        self.rejects(lambda d: d['events'][0].update(endDate='2026-07-31'), 'precedes')

    def test_duplicate_event_ids(self):
        self.rejects(lambda d: d['events'][1].update(id=d['events'][0]['id']), 'duplicate id')

    def test_unknown_source(self):
        self.rejects(lambda d: d['events'][0].update(sourceId='missing'), 'unknown sourceId')

    def test_nonexistent_page(self):
        self.rejects(lambda d: d['events'][0].update(sourcePage=3), 'invalid source page')

    def test_week_gap(self):
        self.rejects(lambda d: d['weeks'].pop(2), 'week gap/overlap')

    def test_week_overlap(self):
        self.rejects(lambda d: d['weeks'][1].update(startDate=d['weeks'][0]['endDate']), 'week gap/overlap')

    def test_week_label_mismatch(self):
        self.rejects(lambda d: d['weeks'][0].update(label='暑六'), 'label/number mismatch')

    def test_no_silent_extra_fields(self):
        self.rejects(lambda d: d['events'][0].update(end_date='2026-08-01'), 'Additional properties')

    def test_changed_snapshot_requires_revision(self):
        new = copy.deepcopy(self.y115)
        new['events'][0]['title'] += '（修訂）'
        with self.assertRaisesRegex(ValueError, 'increased revision'):
            check_history(new, self.y115)
        new['revision'] += 1
        with self.assertRaisesRegex(ValueError, 'later updatedAt'):
            check_history(new, self.y115)
        new['updatedAt'] = (datetime.fromisoformat(self.y115['updatedAt']) + timedelta(days=1)).isoformat().replace('+00:00', 'Z')
        check_history(new, self.y115)

    def test_unchanged_source_entry_cannot_be_renumbered(self):
        new = copy.deepcopy(self.y115)
        new['revision'] += 1
        new['updatedAt'] = (datetime.fromisoformat(self.y115['updatedAt']) + timedelta(days=1)).isoformat().replace('+00:00', 'Z')
        new['events'][0]['id'] = '115-1-999'
        with self.assertRaisesRegex(ValueError, 'stable event ID'):
            check_history(new, self.y115)

    def test_index_hash_detects_partially_updated_download(self):
        import shutil
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name in ['schema', 'years']:
                shutil.copytree(ROOT / name, root / name)
            shutil.copy(ROOT / 'index.json', root / 'index.json')
            path = root / 'years/115.json'
            path.write_text(path.read_text() + '\n')
            with self.assertRaisesRegex(ValueError, 'index hash mismatch'):
                validate(root)

    def test_duplicate_json_keys_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'duplicate.json'
            path.write_text('{"revision":1,"revision":2}')
            with self.assertRaisesRegex(ValueError, 'duplicate JSON key'):
                load(path)


if __name__ == '__main__':
    unittest.main()
