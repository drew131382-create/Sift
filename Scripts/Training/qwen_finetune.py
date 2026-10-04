#!/usr/bin/env python3
"""Local QLoRA for Sift's exact Swift-exported, non-thinking Qwen prompts.

Only the category/arrangement JSON answer is supervised. The prompt is masked.
No remote model IDs, hub downloads, telemetry services or screenshot uploads.
"""
import os
os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1", TOKENIZERS_PARALLELISM="false")
import argparse
import collections
import hashlib
import json
import time
from pathlib import Path

def write(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def prepare(run, base):
    from transformers import AutoTokenizer
    tokenizer = AutoTokenizer.from_pretrained(base, local_files_only=True)
    labels = json.loads((run/"review/annotations.json").read_text())
    manifest = json.loads((run/"label-manifest.json").read_text())
    assert sha(run/"review/annotations.json") == manifest["labelSha256"]
    inputs = json.loads((run/"production-inputs.json").read_text())
    dataset = run/"dataset"; dataset.mkdir(exist_ok=True)
    rows = collections.defaultdict(list)
    chunk_review = []
    for label in labels:
        for number, part in enumerate(inputs[label["id"]]):
            tokens = part["promptTokens"]
            # Actual Swift IDs are authoritative. Check Python agrees byte-for-byte.
            assert tokens == tokenizer.encode(part["prompt"], add_special_tokens=False), label["id"]
            assert len(tokens) <= 2048
            assert label["id"] not in part["payload"]
            target = {"category":label["category"], "arrangement":label["arrangement"]}
            answer = json.dumps(target, ensure_ascii=False, separators=(",", ":"))
            answer_tokens = tokenizer.encode(answer, add_special_tokens=False) + [tokenizer.eos_token_id]
            record = dict(id=label["id"], chunk=number, group=label["group"], split=label["split"],
                          promptTokens=tokens, answerTokens=answer_tokens, target=target,
                          prompt=part["prompt"], payload=part["payload"])
            rows[label["split"]].append(record)
            if len(inputs[label["id"]]) > 1:
                chunk_review.append(record)
    for split, values in rows.items():
        (dataset/f"{split}.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False)+"\n" for r in values))
    write(run/"audit/chunk-label-review.json", chunk_review)
    write(dataset/"manifest.json", dict(labelSha256=manifest["labelSha256"], promptSha256=sha(run/"production-inputs.json"),
          counts={k:len(v) for k,v in rows.items()}, maxPrompt=max(len(r["promptTokens"]) for v in rows.values() for r in v),
          maxAnswer=max(len(r["answerTokens"]) for v in rows.values() for r in v),
          emptyOCRExcluded=manifest["emptyOCR"], splitExposure=manifest["splitPolicy"],
          trainedTask="category / arrangement only; no field strings, filenames or reviewer notes in input",
          promptMasked=True, enableThinking=False, independentAcceptance=False))
    print(json.dumps(json.loads((dataset/"manifest.json").read_text()), ensure_ascii=False, indent=2))

def train_model(run, base, iters, name):
    import numpy as np
    import mlx.core as mx
    import mlx.nn as nn
    import mlx.optimizers as optim
    from mlx.utils import tree_flatten
    from mlx_lm.utils import load
    from mlx_lm.tuner.trainer import TrainingArgs, train, default_loss
    from mlx_lm.tuner.utils import linear_to_lora_layers, print_trainable_parameters
    from mlx_lm.tuner.callbacks import TrainingCallback
    np.random.seed(20261004); mx.random.seed(20261004)
    base = Path(base).resolve()
    assert base.is_dir() and (base/"model.safetensors").is_file()
    original_hash = sha(base/"model.safetensors")
    model, tokenizer = load(str(base))
    assert model.model_type == "qwen3" and model.args.tie_word_embeddings
    model.freeze()
    parameters = dict(rank=8, scale=16.0, dropout=0.0, keys=["self_attn.q_proj", "self_attn.v_proj"])
    linear_to_lora_layers(model, 16, parameters)
    print_trainable_parameters(model)
    out = run/name
    out.mkdir(exist_ok=False)
    config = dict(model=str(base), baseWeightSha256=original_hash, fine_tune_type="lora", num_layers=16,
                  lora_parameters=parameters, seed=20261004, iters=iters, batch_size=1,
                  effectiveBatchSize=2, learning_rate=0.0001, mask_prompt=True,
                  max_seq_length=2113, grad_checkpoint=True, report_to=None,
                  inputManifestSha256=sha(run/"dataset/manifest.json"), labelSha256=sha(run/"review/annotations.json"),
                  selection="lowest validation answer loss; held-out test never selects checkpoints")
    write(out/"adapter_config.json",config)
    def read(split):
        return [json.loads(s) for s in (run/f"dataset/{split}.jsonl").read_text().splitlines()]
    train_rows, valid_rows = read("train"), read("validation")
    # Cap repeated rare-class examples at three copies. These remain the same real
    # source images; report unique image counts separately, never call them new data.
    counts = collections.Counter(r["target"]["category"] for r in train_rows)
    augmented = [r for r in train_rows for _ in range(3 if counts[r["target"]["category"]] <= 8 else 1)]
    def pairs(rows):
        return [(r["promptTokens"]+r["answerTokens"],len(r["promptTokens"])) for r in rows]
    train_data, val_data = pairs(augmented), pairs(valid_rows)
    assert max(len(r[0]) for r in train_data+val_data) <= config["max_seq_length"]
    answer_width = max(len(r["answerTokens"]) for r in train_rows+valid_rows)
    # Equivalent masked CE, project only answer positions to the 152k vocabulary.
    # The entire OCR prompt still passes through all attention layers.
    def answer_loss(model, batch, lengths):
        inputs = batch[:,:-1]
        hidden = model.model(inputs)
        positions = lengths[:,0:1]-1 + mx.arange(answer_width)[None,:]
        indices = mx.minimum(positions,inputs.shape[1]-1)
        selected = mx.take_along_axis(hidden, indices[:,:,None], axis=1)
        logits = model.model.embed_tokens.as_linear(selected)
        targets = mx.take_along_axis(batch[:,1:],indices,axis=1)
        mask = positions < lengths[:,1:]-1
        count = mask.sum()
        ce = nn.losses.cross_entropy(logits,targets).astype(mx.float32)
        return (ce*mask).sum()/count, count
    # Numerically check our memory-saving projection against upstream masked loss.
    tokens, offset = min(train_data,key=lambda r:len(r[0]))
    sample = mx.array([tokens]); lens = mx.array([[offset,len(tokens)]])
    reference = default_loss(model,sample,lens)[0]
    reduced = answer_loss(model,sample,lens)[0]
    mx.eval(reference,reduced)
    difference = abs(reference.item()-reduced.item())
    assert difference < 0.003, difference
    mx.clear_cache(); mx.reset_peak_memory()
    logs=[]
    class Recorder(TrainingCallback):
        best=float("inf")
        def on_train_loss_report(self, info):
            logs.append(dict(kind="train",**info)); write(out/"metrics.json",logs)
        def on_val_loss_report(self, info):
            logs.append(dict(kind="validation",**info)); write(out/"metrics.json",logs)
            if info["iteration"] > 0 and info["val_loss"] < self.best:
                self.best=info["val_loss"]
                mx.save_safetensors(str(out/"best_adapters.safetensors"), dict(tree_flatten(model.trainable_parameters())))
                write(out/"best-checkpoint.json",info)
    started=time.perf_counter()
    train(model=model, optimizer=optim.Adam(learning_rate=config["learning_rate"]),
          train_dataset=train_data,val_dataset=val_data,
          args=TrainingArgs(batch_size=1,iters=iters,val_batches=-1,steps_per_report=10,
                            steps_per_eval=40,steps_per_save=40,max_seq_length=config["max_seq_length"],
                            adapter_file=str(out/"adapters.safetensors"),grad_checkpoint=True,grad_accumulation_steps=2),
          loss=answer_loss,training_callback=Recorder())
    assert sha(base/"model.safetensors") == original_hash
    write(out/"training-summary.json",dict(seconds=time.perf_counter()-started,uniqueTrainImages=len(set(r["id"] for r in train_rows)),
          uniqueValidationImages=len(set(r["id"] for r in valid_rows)),trainingChunks=len(train_rows),augmentedExamples=len(augmented),
          peakMLXBytes=mx.get_peak_memory(),maskedLossEquivalenceDifference=difference,
          trainableParameters=sum(v.size for _,v in tree_flatten(model.trainable_parameters())),
          baseWeightUnchanged=True,completedIterations=iters,selected=json.loads((out/"best-checkpoint.json").read_text()),
          independentAcceptance=False))
    print("TRAINING COMPLETE",out,flush=True)

def judge(run, base, adapter, output, split):
    import mlx.core as mx
    from mlx_lm import generate
    from mlx_lm.utils import load
    from mlx_lm.sample_utils import make_sampler
    model, tokenizer = load(str(Path(base).resolve()),adapter_path=adapter)
    # MLX consumes the exported IDs directly, avoiding a second chat template.
    paths = [run/f"dataset/{s}.jsonl" for s in ((split,) if split != "all" else ("train","validation","test"))]
    rows=[json.loads(line) for p in paths for line in p.read_text().splitlines()]
    results=[]; start=time.perf_counter()
    for i,r in enumerate(rows,1):
        t=time.perf_counter()
        raw=generate(model,tokenizer,prompt=r["promptTokens"],max_tokens=64,sampler=make_sampler(temp=0),verbose=False)
        error=None; parsed=None
        try:
            parsed=json.loads(raw.strip())
            assert set(parsed) == {"category","arrangement"}
        except Exception as exc:
            error=f"Invalid JSON: {type(exc).__name__}"
        result=dict(id=r["id"],chunk=r["chunk"],split=r["split"],expected=r["target"],output=raw,parsed=parsed,
                    seconds=time.perf_counter()-t,error=error,exact=parsed==r["target"])
        results.append(result)
        write(output,dict(mode="Python greedy generation, no grammar; identical Swift prompt IDs; not full image pipeline",
              base=str(base),adapter=adapter,results=results,complete=i==len(rows),elapsedSeconds=time.perf_counter()-start,
              peakMLXBytes=mx.get_peak_memory(),independentAcceptance=False))
        print(f"{i}/{len(rows)} {r['id']} {r['target']} -> {parsed} {result['seconds']:.2f}s",flush=True)
    print("JUDGMENT COMPLETE",output,flush=True)

def main():
    p=argparse.ArgumentParser(); p.add_argument("mode",choices=["prepare","train","judge"])
    p.add_argument("--run",type=Path,required=True); p.add_argument("--base",required=True)
    p.add_argument("--iters",type=int,default=360); p.add_argument("--name",default="run-01")
    p.add_argument("--adapter"); p.add_argument("--output",type=Path); p.add_argument("--split",default="all",choices=["train","validation","test","all"])
    a=p.parse_args()
    if a.mode=="prepare": prepare(a.run,a.base)
    elif a.mode=="train": train_model(a.run,a.base,a.iters,a.name)
    else: judge(a.run,a.base,a.adapter,a.output,a.split)

if __name__=="__main__": main()
