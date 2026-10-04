#!/usr/bin/env python3
"""Select by validation classification quality, never by held-out test outputs."""
import os
os.environ.update(HF_HUB_OFFLINE="1",TRANSFORMERS_OFFLINE="1",HF_HUB_DISABLE_TELEMETRY="1",TOKENIZERS_PARALLELISM="false")
import argparse
import collections
import json
from pathlib import Path
import mlx.core as mx
from mlx_lm import generate
from mlx_lm.utils import load
from mlx_lm.sample_utils import make_sampler
from qwen_compare import GROUP

def write(path,value):Path(path).write_text(json.dumps(value,ensure_ascii=False,indent=2)+"\n")
def main():
    p=argparse.ArgumentParser();p.add_argument("--run",type=Path,required=True);p.add_argument("--base",required=True)
    a=p.parse_args();training=a.run/"run-01"
    rows=[json.loads(line) for line in (a.run/"dataset/validation.jsonl").read_text().splitlines()]
    model,tokenizer=load(str(Path(a.base).resolve()),adapter_path=str(a.run/"selected-adapter"))
    outputs=[]
    # All saved checkpoints, plus the lowest-loss checkpoint; no test labels read.
    paths=sorted(training.glob("[0-9]*_adapters.safetensors"))+[training/"best_adapters.safetensors"]
    for path in paths:
        model.load_weights(str(path),strict=False);mx.eval(model.parameters())
        results=[]
        for row in rows:
            raw=generate(model,tokenizer,prompt=row["promptTokens"],max_tokens=64,sampler=make_sampler(temp=0),verbose=False)
            prediction=None
            try:
                out=json.loads(raw)
                assert set(out)=={"category","arrangement"} and out["category"] in GROUP
                expected_arrangements=("参考",) if out["category"]=="参考收藏" else ("确认","通知","行程") if out["category"]=="明确安排" else ("无",)
                assert out["arrangement"] in expected_arrangements
                prediction=out
            except Exception: pass
            wanted=GROUP[row["target"]["category"]];actual=GROUP[prediction["category"]] if prediction else "失败"
            results.append(dict(id=row["id"],expected=row["target"],predicted=prediction,raw=raw,
                      expectedGroup=wanted,predictedGroup=actual,groupCorrect=wanted==actual,exact=row["target"]==prediction))
        classes=sorted({r["expectedGroup"] for r in results});f1=[]
        for group in classes:
            tp=sum(r["expectedGroup"]==r["predictedGroup"]==group for r in results)
            fp=sum(r["expectedGroup"]!=group and r["predictedGroup"]==group for r in results)
            fn=sum(r["expectedGroup"]==group and r["predictedGroup"]!=group for r in results)
            f1.append(2*tp/(2*tp+fp+fn) if 2*tp+fp+fn else 0)
        output=dict(checkpoint=str(path),n=len(results),macroF1=sum(f1)/len(f1),
             groupCorrect=sum(r["groupCorrect"] for r in results),exact=sum(r["exact"] for r in results),
             falseInclude=sum(r["expectedGroup"]=="跳过" and r["predictedGroup"] in ("领取","日程","消费","收藏") for r in results),results=results)
        outputs.append(output)
        write(a.run/"validation-checkpoint-comparison.json",dict(results=outputs,complete=len(outputs)==len(paths),
                    selection="validation macro F1, then group correctness, then exact category/arrangement; no test used",independentAcceptance=False))
        print(path.name,"macro F1",round(output["macroF1"],4),"correct",output["groupCorrect"],"/",len(results),flush=True)
    winner=max(outputs,key=lambda r:(r["macroF1"],r["groupCorrect"],r["exact"],-r["falseInclude"]))
    write(a.run/"validation-selected-checkpoint.json",{k:v for k,v in winner.items() if k!="results"})
    print("VALIDATION SELECTED",winner["checkpoint"],flush=True)

if __name__=="__main__":main()
