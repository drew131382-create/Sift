"""Developer-only pinned download. Application inference never calls this script."""
import argparse
import hashlib
import json
import urllib.request
from pathlib import Path

MODEL="hfl/rbt3"
REVISION="0aa0527ff4170f29e1dfd3eb6ef60dc67e1bf75c"
WEIGHTS_SHA="3e04f7477f55dffce2a2fbc4d0ba35068415162a9e92e3d5cc74a49781ba4eb0"
FILES=["config.json","pytorch_model.bin","tokenizer.json","tokenizer_config.json","special_tokens_map.json","vocab.txt","README.md"]


def main():
    ap=argparse.ArgumentParser();ap.add_argument("--output",required=True);args=ap.parse_args()
    root=Path(args.output);root.mkdir(parents=True,exist_ok=True)
    for name in FILES:
        dest=root/name
        if not dest.exists():
            request=urllib.request.Request(f"https://huggingface.co/{MODEL}/resolve/{REVISION}/{name}",headers={"User-Agent":"Sift-training-resource-preparation"})
            with urllib.request.urlopen(request,timeout=120) as response, (root/(name+".tmp")).open("wb") as f:
                while part:=response.read(1024*1024): f.write(part)
            (root/(name+".tmp")).replace(dest)
        if name=="pytorch_model.bin": assert hashlib.sha256(dest.read_bytes()).hexdigest()==WEIGHTS_SHA
        print(name,dest.stat().st_size,flush=True)
    with urllib.request.urlopen("https://www.apache.org/licenses/LICENSE-2.0.txt",timeout=30) as response:
        (root/"LICENSE-2.0.txt").write_bytes(response.read())
    (root/"NOTICE.txt").write_text(f"Base model: {MODEL}\nRevision: {REVISION}\nUpstream: https://huggingface.co/{MODEL}\nLicense: Apache-2.0 per upstream model metadata\nChinese RoBERTa/BERT-wwm by HFL; preserve source attribution.\n")
    (root/"verified-files.json").write_text(json.dumps({name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in FILES},indent=2)+"\n")


if __name__=="__main__":main()
