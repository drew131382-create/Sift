#!/usr/bin/env python3
"""Fuse a selected adapter into a separate 4-bit developer candidate, offline."""
import os
os.environ.update(HF_HUB_OFFLINE="1",TRANSFORMERS_OFFLINE="1",HF_HUB_DISABLE_TELEMETRY="1")
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def write(path,value):Path(path).write_text(json.dumps(value,ensure_ascii=False,indent=2)+"\n")

def main():
    p=argparse.ArgumentParser();p.add_argument("--run",type=Path,required=True)
    p.add_argument("--base",type=Path,required=True);p.add_argument("--training",default="run-01")
    p.add_argument("--checkpoint",type=Path)
    p.add_argument("--output-name",default="candidate-model")
    p.add_argument("--adapter-name",default="selected-adapter")
    a=p.parse_args();base=a.base.resolve();training=a.run/a.training
    config=json.loads((training/"adapter_config.json").read_text())
    assert sha(base/"model.safetensors")==config["baseWeightSha256"]
    assert sha(a.run/"review/annotations.json")==config["labelSha256"]
    assert (training/"training-summary.json").is_file(),"Incomplete training is not a candidate"
    chosen=a.run/a.adapter_name;chosen.mkdir(exist_ok=False)
    selected=a.checkpoint or training/"best_adapters.safetensors"
    assert selected.resolve().parent==training.resolve(),"Checkpoint must belong to this training run"
    shutil.copyfile(selected,chosen/"adapters.safetensors")
    shutil.copyfile(training/"adapter_config.json",chosen/"adapter_config.json")
    fused=a.run/a.output_name
    assert not fused.exists(),"Do not overwrite an evaluated candidate"
    subprocess.run([sys.executable,"-m","mlx_lm","fuse","--model",str(base),
                    "--adapter-path",str(chosen),"--save-path",str(fused)],check=True,env=os.environ.copy())
    # No vocabulary or template training took place. HF's save_pretrained rewrites
    # tokenizer metadata; preserve the exact resources used by Swift production.
    for name in ("tokenizer.json", "tokenizer_config.json", "vocab.json", "merges.txt"):
        shutil.copyfile(base/name,fused/name)
    if (fused/"chat_template.jinja").exists():
        (fused/"chat_template.jinja").unlink()
    shutil.copyfile(base/"LICENSE",fused/"LICENSE")
    assert json.loads((fused/"config.json").read_text())["quantization"]["bits"]==4
    merged_sha=sha(fused/"model.safetensors")
    assert merged_sha!=config["baseWeightSha256"],"Training must change actual weights"
    lineage=dict(model="local/Sift-Qwen3-0.6B-QLoRA",revision=merged_sha,
         baseModel="Qwen/Qwen3-0.6B-MLX-4bit",baseRevision="173234aa840d113125e9f2271100ddbaf16c9620",
         baseWeightSha256=config["baseWeightSha256"],adapterSha256=sha(chosen/"adapters.safetensors"),
         labelSha256=config["labelSha256"],promptSha256=sha(a.run/"production-inputs.json"),
         selectedCheckpoint=json.loads((a.run/"validation-selected-checkpoint.json").read_text()) if a.checkpoint else json.loads((training/"best-checkpoint.json").read_text()),
         humanConfirmed=False,independentAcceptance=False,numericFieldAccuracyEstablished=False,
         deployedToApplication=False,installedOnIPhone=False,license="Apache-2.0",quantizationBits=4)
    write(fused/"training-provenance.json",lineage)
    files=[]
    for path in sorted(fused.iterdir()):
        if path.is_file() and path.name!="manifest.json":
            files.append(dict(name=path.name,bytes=path.stat().st_size,sha256=sha(path)))
    write(fused/"manifest.json",dict(model=lineage["model"],revision=merged_sha,files=files))
    assert sha(base/"model.safetensors")==config["baseWeightSha256"]
    write(a.run/("candidate-artifact.json" if a.output_name=="candidate-model" else a.output_name+"-artifact.json"),dict(**lineage,directory=str(fused),
          modelDirectoryBytes=sum(r["bytes"] for r in files)+(fused/"manifest.json").stat().st_size,
          adapterBytes=(chosen/"adapters.safetensors").stat().st_size,baseWeightUnchanged=True))
    print("FUSED CANDIDATE",fused,"revision",merged_sha,flush=True)

if __name__=="__main__":main()
