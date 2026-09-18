#!/usr/bin/env python3
"""Update the app/widget offline snapshot from the validated local GitHub data.
Data-only publications need not run this; run before an app release to refresh its offline fallback.
"""
from pathlib import Path
import json
import shutil
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'calendar-data/scripts'))
from validate import validate

for result in validate():
    print(result)
source = root / 'calendar-data'
output = root / 'Resources/AcademicCalendar'
index = json.loads((source / 'index.json').read_text())
output.mkdir(parents=True, exist_ok=True)
for entry in index['calendars']:
    target = output / entry['path']
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source / entry['path'], target)
shutil.copyfile(source / 'index.json', output / 'index.json')
print('Updated shared app/widget offline snapshot')
