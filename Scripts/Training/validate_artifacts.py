"""Integrity and deployment checks, not an accuracy acceptance test."""
import argparse
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from transformers import AutoTokenizer
from train_classifier import CLASSES, LENGTH, digest, encode_document, write


def main():
    ap=argparse.ArgumentParser();ap.add_argument("--dataset",required=True);ap.add_argument("--base",required=True);ap.add_argument("--run",required=True);args=ap.parse_args()
    root=Path(args.run);rows=json.loads(Path(args.dataset).read_text());config=json.loads((root/"configuration.json").read_text())
    assert config["datasetSha256"]==digest(args.dataset)
    assert len(rows)==len({r["id"] for r in rows})==len({r["sha256"] for r in rows})
    assert all(digest(r["image"])==r["sha256"] for r in rows)
    split_groups=[{r["group"] for r in rows if r["split"]==s} for s in ["train","validation","test"]]
    assert all(not a&b for i,a in enumerate(split_groups) for b in split_groups[i+1:])
    tokenizer=AutoTokenizer.from_pretrained(root/"tokenizer",local_files_only=True)
    for r in rows:
        f=encode_document(r["document"],tokenizer)
        assert f["input_ids"].shape==(f["windows"],LENGTH)
        assert f["geometry"].shape==(f["windows"],LENGTH,5)
        assert torch.isfinite(f["geometry"]).all()
    # A deliberately long last block must reach the last window, including its
    # location. This exercises coverage only; no synthetic data enters training.
    long={"blocks":[{"text":"资料文字"*1000+"终点词","boundingBox":[[.2,.1],[.4,.1]],"confidence":.9}]}
    f=encode_document(long,tokenizer)
    last=int(f["attention_mask"][-1].sum())
    tail=f["input_ids"][-1,1:last-2].tolist()
    assert tail[-len(tokenizer.encode("终点词",add_special_tokens=False)):]==tokenizer.encode("终点词",add_special_tokens=False)
    checkpoint=torch.load(root/"best.pt",map_location="cpu",weights_only=True)
    base=torch.load(Path(args.base)/"pytorch_model.bin",map_location="cpu",weights_only=True)
    name="encoder.layer.0.attention.self.query.weight"
    delta=float((checkpoint["state_dict"]["encoder."+name]-base["bert."+name]).abs().max())
    assert delta>0, "Encoder must have been fine tuned, not just renamed"
    exported=json.loads((root/"coreml-verification.json").read_text())
    assert exported["categoryAgreementWithPyTorch"]==len(rows)
    assert exported["arrangementAgreementWithPyTorch"]==len(rows)
    package=root/"SiftScreenshotClassifier.mlpackage"
    compiled=ct.models.utils.compile_model(str(package),destination_path=str(root/"SiftScreenshotClassifier.mlmodelc"))
    spec=ct.models.MLModel(str(package),skip_model_load=True).get_spec()
    assert {i.name for i in spec.description.input}=={"input_ids","attention_mask","geometry"}
    assert {o.name for o in spec.description.output}=={"category_logits","arrangement_logits"}
    compiled_path=Path(compiled)
    report={"originalImagesVerified":len(rows),"groupSplitsDisjoint":True,"allOCRInputsValid":True,"longTailCovered":True,"actualEncoderMaximumWeightChange":delta,"compiledModel":str(compiled_path),"compiledBytes":sum(p.stat().st_size for p in compiled_path.rglob("*") if p.is_file()),"coremlLabelAgreement":exported["categoryAgreementWithPyTorch"],"accuracyAcceptance":False,"iPhoneRuntimeVerified":False}
    write(root/"integrity-checks.json",report);print(json.dumps(report,indent=2),flush=True)


if __name__=="__main__":main()
