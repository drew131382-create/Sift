#!/usr/bin/env python3
"""Compare actual full-image runs on frozen, reviewed group labels.

This is a development regression report, not independent human acceptance.
All failures remain failures; direct extraction is separated from model paths.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import statistics

GROUPS = {
    "delivery": "pickup", "pickup": "pickup",
    "event": "schedule", "health": "schedule",
    "payment": "commerce", "shopping": "commerce", "documentation": "commerce",
    "learning": "collection", "place": "collection", "technical": "collection", "inspiration": "collection",
}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def percentile(values, p):
    values = sorted(values)
    import math
    return values[max(0, math.ceil(len(values)*p)-1)] if values else None


def comparable_ocr(document):
    # OCRBlock UUIDs are fresh bookkeeping, never model inputs. Keep all actual
    # text, order, geometry and confidence in this equality check.
    return dict(document, blocks=[{k:v for k,v in block.items() if k!='id'} for block in document['blocks']])


def measure(gold, rows, summary):
    assert len(rows) == len(gold) and len({x['id'] for x in rows}) == len(rows)
    assert {x['id'] for x in rows} == set(gold)
    counts = Counter()
    details = {"falsePositiveIDs": [], "missedIDs": [], "wrongGroupIDs": [], "failureIDs": []}
    by_group = {}
    for row in rows:
        label = gold[row['id']]
        expected = label['category'] != 'ignored'
        actual_group = GROUPS.get(row.get('category')) if row['accepted'] else 'ignored'
        failed = bool(row.get('error'))
        correct = not failed and actual_group == label['category']
        counts['decisionCorrect'] += correct
        counts['failures'] += failed
        counts['admitted'] += row['accepted']
        counts['truePositive'] += row['accepted'] and expected
        counts['falsePositive'] += row['accepted'] and not expected
        counts['falseNegativeIncludingFailure'] += expected and not row['accepted']
        counts['correctlyIgnored'] += not expected and not row['accepted'] and not failed
        counts['wrongGroup'] += row['accepted'] and expected and actual_group != label['category']
        group = by_group.setdefault(label['category'], dict(samples=0, correct=0, admitted=0, failures=0))
        group['samples'] += 1; group['correct'] += correct; group['admitted'] += row['accepted']; group['failures'] += failed
        if failed: details['failureIDs'].append(row['id'])
        if row['accepted'] and not expected: details['falsePositiveIDs'].append(row['id'])
        if expected and not row['accepted']: details['missedIDs'].append(row['id'])
        if row['accepted'] and expected and actual_group != label['category']: details['wrongGroupIDs'].append(row['id'])
    useful = sum(x['category'] != 'ignored' for x in gold.values())
    times = [r['seconds'] for r in rows]
    model_times = [r['metrics']['seconds'] for r in rows if (r.get('metrics') or {}).get('path') in ['model', 'hybrid']]
    model_success_times = [r['metrics']['seconds'] for r in rows if not r.get('error') and (r.get('metrics') or {}).get('path') in ['model', 'hybrid']]
    paths = {}
    for path in sorted({(r.get('metrics') or {}).get('path', 'no-path') for r in rows}):
        subset = [r for r in rows if (r.get('metrics') or {}).get('path', 'no-path') == path]
        paths[path] = dict(samples=len(subset), successes=sum(not r.get('error') for r in subset), failures=sum(bool(r.get('error')) for r in subset))
    return dict(counts, samples=len(rows), expectedUseful=useful,
                accuracy=counts['decisionCorrect']/len(rows),
                precision=counts['truePositive']/counts['admitted'] if counts['admitted'] else None,
                recall=counts['truePositive']/useful, byGroup=by_group, paths=paths,
                errorKinds=dict(Counter(r.get('errorKind') or 'other' for r in rows if r.get('error'))),
                imageMedianSeconds=statistics.median(times), imageP95Seconds=percentile(times,.95),
                modelMedianSeconds=statistics.median(model_times) if model_times else None,
                modelP95Seconds=percentile(model_times,.95),
                successfulModelMedianSeconds=statistics.median(model_success_times) if model_success_times else None,
                mlxPeakBytes=summary['mlxPeakBytes'], modelCalls=summary['modelCalls'],
                inputTokens=sum(sum((r.get('metrics') or {}).get('inputTokens',[])) for r in rows),
                outputTokens=sum(sum((r.get('metrics') or {}).get('outputTokens',[])) for r in rows),
                numericCorrect=summary['numericCorrect'], numericExpected=summary['numericExpected'],
                unexpectedNumeric=summary['unexpectedNumeric'], forbiddenViolations=summary['forbiddenViolations'],
                **details)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--annotations',type=Path,required=True)
    ap.add_argument('--qwen',type=Path,required=True)
    ap.add_argument('--lfm',type=Path,required=True)
    ap.add_argument('--output',type=Path,required=True)
    args=ap.parse_args()
    gold_rows=json.loads(args.annotations.read_text());gold={x['id']:x for x in gold_rows}
    assert len(gold)==len(gold_rows)
    result={'formalAcceptance':False,'humanConfirmed':all(x.get('humanConfirmed') for x in gold_rows),
            'numericGoldComplete':all(x.get('numericGoldComplete') for x in gold_rows),
            'annotationsSHA256':sha(args.annotations),'models':{}}
    runs={}
    ocr={}
    for key,path in [('qwen',args.qwen),('lfm',args.lfm)]:
        rows=json.loads(path.read_text());runs[key]={x['id']:x for x in rows}
        summary=json.loads(path.with_suffix('.summary.json').read_text())
        assert summary['imageReadForOCRThisRun'] and not summary['cachedVisionOCR'] and not summary['replayedSemanticJudgments']
        assert not summary['importedClassifierJudgments'] and summary['modelImageInput'] is False
        result['models'][key]=measure(gold,rows,summary)
        result['models'][key].update(modelID=summary['modelID'],modelRevision=summary['modelRevision'],policy=summary['policy'],resultsSHA256=sha(path))
        ocr[key]=json.loads(path.with_suffix('.ocr.json').read_text())
    result['ocrIdenticalDocuments']=sum(comparable_ocr(ocr['qwen'][i])==comparable_ocr(ocr['lfm'][i]) for i in gold)
    result['ocrMismatchIDs']=[i for i in gold if comparable_ocr(ocr['qwen'][i])!=comparable_ocr(ocr['lfm'][i])]
    result['changedCases']=[{'id':i,'expected':gold[i]['category'],
                            'qwen':{'category':runs['qwen'][i].get('category'),'error':runs['qwen'][i].get('errorKind'),'accepted':runs['qwen'][i]['accepted']},
                            'lfm':{'category':runs['lfm'][i].get('category'),'error':runs['lfm'][i].get('errorKind'),'accepted':runs['lfm'][i]['accepted']}}
                           for i in gold if (runs['qwen'][i]['accepted'],runs['qwen'][i].get('category'),runs['qwen'][i].get('errorKind')) != (runs['lfm'][i]['accepted'],runs['lfm'][i].get('category'),runs['lfm'][i].get('errorKind'))]
    args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:{n:v[n] for n in ['samples','decisionCorrect','truePositive','falsePositive','falseNegativeIncludingFailure','wrongGroup','failures','modelMedianSeconds','mlxPeakBytes']} for k,v in result['models'].items()},indent=2))


if __name__=='__main__':main()
