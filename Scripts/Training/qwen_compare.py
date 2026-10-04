#!/usr/bin/env python3
"""Compare frozen assistant labels with actual base/QLoRA generations."""
import argparse
import collections
import json
import statistics
from pathlib import Path

GROUP = {"领取通知":"领取", "明确安排":"日程", "付款凭证":"消费", "已有订单":"消费", "其他凭证":"消费", "参考收藏":"收藏", "无关":"跳过", "不确定":"待判定"}
PRIORITY = {"领取":0,"日程":1,"消费":2,"收藏":3,"待判定":4,"跳过":5}

def score(path, labels):
    raw=json.loads(path.read_text()); assert raw["complete"]
    byid=collections.defaultdict(list)
    for r in raw["results"]: byid[r["id"]].append(r)
    results=[]
    for label in labels:
        rows=byid.get(label["id"],[])
        if not rows:
            # Only OCR-empty screenshots are excluded from language-model inference.
            continue
        valid=all(not r["error"] and isinstance(r["parsed"],dict) and r["parsed"].get("category") in GROUP for r in rows)
        prediction=None
        if valid:
            prediction=min((r["parsed"] for r in rows),key=lambda r:PRIORITY[GROUP[r["category"]]])
        wanted={"category":label["category"],"arrangement":label["arrangement"]}
        actual=GROUP.get(prediction["category"],"失败") if prediction else "失败"
        expected=GROUP[label["category"]]
        results.append(dict(id=label["id"],split=label["split"],expected=wanted,predicted=prediction,
                   expectedGroup=expected,predictedGroup=actual,groupCorrect=expected==actual,exact=prediction==wanted,
                   seconds=sum(r["seconds"] for r in rows),jsonValid=valid,
                   falseInclude=expected=="跳过" and actual in ("领取","日程","消费","收藏"),
                   missedInclude=expected in ("领取","日程","消费","收藏") and actual in ("失败","跳过","待判定")))
    metrics={}
    for split in ("train","validation","test","heldout","all"):
        sample=[r for r in results if split=="all" or r["split"]==split or split=="heldout" and r["split"] in ("validation","test")]
        n=len(sample); groups=sorted(set(r["expectedGroup"] for r in sample)); perclass={}
        for group in groups:
            tp=sum(r["expectedGroup"]==group and r["predictedGroup"]==group for r in sample)
            fp=sum(r["expectedGroup"]!=group and r["predictedGroup"]==group for r in sample)
            fn=sum(r["expectedGroup"]==group and r["predictedGroup"]!=group for r in sample)
            perclass[group]=dict(support=tp+fn,tp=tp,fp=fp,fn=fn,f1=2*tp/(2*tp+fp+fn) if 2*tp+fp+fn else 0)
        metrics[split]=dict(n=n,groupCorrect=sum(r["groupCorrect"] for r in sample),exact=sum(r["exact"] for r in sample),
          groupAccuracy=sum(r["groupCorrect"] for r in sample)/n if n else None,
          exactAccuracy=sum(r["exact"] for r in sample)/n if n else None,
          falseInclude=sum(r["falseInclude"] for r in sample), missedInclude=sum(r["missedInclude"] for r in sample),
          malformed=sum(not r["jsonValid"] for r in sample), macroF1=statistics.mean(c["f1"] for c in perclass.values()) if perclass else None,
          perClass=perclass,medianSeconds=statistics.median(r["seconds"] for r in sample) if sample else None)
    return dict(mode=raw["mode"],metrics=metrics,results=results,peakMLXBytes=raw["peakMLXBytes"],independentAcceptance=False)

def main():
    p=argparse.ArgumentParser();p.add_argument("--run",type=Path,required=True)
    p.add_argument("--baseline",type=Path,required=True);p.add_argument("--candidate",type=Path,required=True)
    p.add_argument("--output",type=Path,required=True);a=p.parse_args()
    labels=json.loads((a.run/"review/annotations.json").read_text())
    base=score(a.baseline,labels);candidate=score(a.candidate,labels)
    before={r["id"]:r for r in base["results"]}
    regressions=[dict(id=r["id"],split=r["split"],before=before[r["id"]]["predicted"],after=r["predicted"],expected=r["expected"]) for r in candidate["results"] if before[r["id"]]["groupCorrect"] and not r["groupCorrect"]]
    improvements=[dict(id=r["id"],split=r["split"],before=before[r["id"]]["predicted"],after=r["predicted"],expected=r["expected"]) for r in candidate["results"] if not before[r["id"]]["groupCorrect"] and r["groupCorrect"]]
    output=dict(baseline=base,candidate=candidate,regressions=regressions,improvements=improvements,
      independentAcceptance=False, limitation="Assistant labels; development holdouts previously observed; no complete numeric-field gold and no iPhone timing. Python unconstrained generation is separate from production guided extraction.")
    a.output.write_text(json.dumps(output,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps(dict(baseline=base["metrics"],candidate=candidate["metrics"]),ensure_ascii=False,indent=2))

if __name__=="__main__":main()
