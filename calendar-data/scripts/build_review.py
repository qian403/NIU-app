#!/usr/bin/env python3
"""Render a reproducible human review page. JSON remains the source of truth."""
import argparse
from validate import ROOT, load


def cell(value):
    return str(value).replace('|', '\\|').replace('\n', '<br>')


def render():
    lines = ['# 校方年度行事曆資料核對表', '',
             '本表由 `python3 calendar-data/scripts/build_review.py` 產生，請修改年度 JSON 後重新產生。', '',
             '日期區間包含結束日。週次忠實呈現 PDF 週次欄，不代表該列每一天都上課或放假。', '',
             '僅核對指定 PDF 的版本，未宣稱取代各主管單位的後續公告。', '']
    for entry in load(ROOT / 'index.json')['calendars']:
        data = load(ROOT / entry['path'])
        lines += [f'## {data["academicYear"]} 學年度', '',
                  f'{data["startDate"]} ～ {data["endDate"]}；{len(data["events"])} 筆事件、{len(data["weeks"])} 段週次。', '']
        for source in data['sources']:
            lines += [f'來源：[{source["title"]}]({source["url"]})；校方維護日期 {source["maintainedOn"]}；文件版本 {source["version"] or "未標示"}。', '']
        lines += ['| 學期 | 學期開始 | 學期結束 | 正式開學 |', '| --- | --- | --- | --- |']
        for semester in data['semesters']:
            lines.append('| ' + ' | '.join(str(semester[k]) for k in ['number', 'startDate', 'endDate', 'classesStartDate']) + ' |')
        lines += ['', '### 事件', '', '| 固定 ID | 起日 | 迄日 | 標題 | 備註 | PDF 頁 | 原文日期條目 |', '| --- | --- | --- | --- | --- | --- | --- |']
        for e in data['events']:
            values = [e['id'], e['startDate'], e['endDate'], e['title'], e['note'] or '', e['sourcePage'], e['sourceText']]
            lines.append('| ' + ' | '.join(map(cell, values)) + ' |')
        lines += ['', '### PDF 週次', '', '| 起日 | 迄日 | 學期 | 標示 | PDF 頁 |', '| --- | --- | --- | --- | --- |']
        for w in data['weeks']:
            lines.append('| ' + ' | '.join(cell(w[k]) for k in ['startDate', 'endDate', 'semester', 'label', 'sourcePage']) + ' |')
        lines += ['', '### 校方備註與修訂說明', '']
        lines += [f'- {n["text"]}' for n in data['notes']]
        for source in data['sources']:
            lines += [f'- {t}' for t in source['approvalNotes']]
            lines += [f'- 更新說明（第 {"、".join(map(str, n["pages"]))} 頁）：{n["text"]}' for n in source['updateNotes']]
        lines += ['']
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    path = ROOT / 'REVIEW.md'
    rendered = render()
    if args.check:
        if not path.exists() or path.read_text(encoding='utf-8') != rendered:
            raise SystemExit('REVIEW.md is stale; run scripts/build_review.py')
        print('REVIEW.md matches the data')
    else:
        path.write_text(rendered, encoding='utf-8')
        print('Updated REVIEW.md')


if __name__ == '__main__':
    main()
