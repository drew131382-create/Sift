#!/usr/bin/env python3
"""Create an unlabelled local manifest; this does not annotate or upload images."""
import argparse
import json
import hashlib
from pathlib import Path
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("screenshots", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
if args.output.exists():
    parser.error("Refusing to overwrite an existing annotation manifest")
images = sorted(p for p in args.screenshots.iterdir() if p.suffix.lower() in {".png", ".jpg", ".jpeg", ".heic"})
records = [{"id": f"real-{i:03d}", "origin": "pending-human-review", "image": str(p.resolve()), "reviewer": "", "reviewedAt": "", "lines": [], "accepted": None, "category": None, "numeric": {}, "expectedReview": None, "forbidden": {}, "expectedFields": None, "expectedFailure": False, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for i,p in enumerate(images,1)]
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n")
print(f"Created {len(records)} unlabelled records; a human must review every image before acceptance.")
