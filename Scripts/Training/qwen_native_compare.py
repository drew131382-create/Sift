#!/usr/bin/env python3
"""Normalize genuine Swift guided outputs for the frozen-label comparison."""
import argparse
import json
from pathlib import Path
from qwen_compare import score

def normalize(path,labels,output):
    data=json.loads(path.read_text());assert data["complete"]
    lookup={r["id"]:r for r in labels};results=[];empty=[]
    for image in data["results"]:
        label=lookup[image["id"]]
        if image["emptyOCR"]:
            empty.append(image["id"]);continue
        outputs=image["outputs"] or [""]
        for chunk,raw in enumerate(outputs):
            parsed=None;error=image["error"]
            try:
                parsed=json.loads(raw)
                assert set(parsed)=={"category","arrangement"}
            except Exception: error=error or "invalid JSON"
            wanted={k:label[k] for k in ("category","arrangement")}
            results.append(dict(id=image["id"],chunk=chunk,split=label["split"],expected=wanted,output=raw,
                         parsed=parsed,error=error,exact=parsed==wanted,seconds=image["seconds"]/len(outputs)))
    normalized=dict(mode=data["mode"],results=results,complete=True,peakMLXBytes=data["mlxPeakBytes"],
                    excludedEmptyOCR=empty,model=data["model"],revision=data["revision"],independentAcceptance=False)
    output.write_text(json.dumps(normalized,ensure_ascii=False,indent=2)+"\n")
    return score(output,labels)

def main():
    p=argparse.ArgumentParser();p.add_argument("--run",type=Path,required=True)
    p.add_argument("--baseline",type=Path,required=True);p.add_argument("--candidate",type=Path,required=True)
    p.add_argument("--output",type=Path,required=True);a=p.parse_args()
    labels=json.loads((a.run/"review/annotations.json").read_text())
    base=normalize(a.baseline,labels,a.output.with_name(a.output.stem+"-baseline-normalized.json"))
    candidate=normalize(a.candidate,labels,a.output.with_name(a.output.stem+"-candidate-normalized.json"))
    output=dict(baseline=base,candidate=candidate,independentAcceptance=False,
       limitation="Actual Swift production JSON constraint and KV precision. Cached Vision OCR; scene judgment only, no card/field admission; assistant development labels, not independent human acceptance.")
    a.output.write_text(json.dumps(output,ensure_ascii=False,indent=2)+"\n")
    for name,data in (("baseline",base),("candidate",candidate)):
        print(name,data["metrics"]["heldout"])

if __name__=="__main__":main()
