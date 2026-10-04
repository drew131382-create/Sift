"""Freeze reviewed annotations, source checksums and grouped splits before training.

Private review JSON contains an explicit decision for EVERY image. No model outputs
are consulted. OCR/evidence stay in the output directory, outside the application.
"""
import argparse
import hashlib
import json
import random
from collections import Counter
from pathlib import Path

CLASSES = ["ignored", "pickup", "schedule", "commerce", "collection"]
ARRANGEMENTS = ["none", "reference", "confirmed", "travel", "notice", "tentative", "cancelled"]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--review", required=True)
    ap.add_argument("--ocr", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    root = Path(args.output); root.mkdir(parents=True, exist_ok=True)
    assert not (root/"dataset.json").exists(), "Frozen dataset exists; create a new version rather than overwrite splits"
    annotations = json.loads(Path(args.review).read_text())
    ocr = json.loads(Path(args.ocr).read_text())
    assert len({a["id"] for a in annotations}) == len(annotations)
    assert set(ocr) == {a["id"] for a in annotations}, "All source images need review"
    assert len({a["sha256"] for a in annotations}) == len(annotations), "Duplicate images require explicit grouping/review"
    for a in annotations:
        assert a["category"] in CLASSES and a["arrangement"] in ARRANGEMENTS
        assert a["reviewer"] == "Codex assistant" and a["reason"]
        assert sha(a["image"]) == a["sha256"], a["id"]
        blocks = ocr[a["id"]]["blocks"]
        assert all(0 <= i < len(blocks) for i in a["evidenceBlocks"])
        if a["category"] != "ignored":
            assert a["evidenceBlocks"], a["id"]
        a["document"] = ocr[a["id"]]
    # Exhaustive, reproducible group-stratified assignment. Select on class counts
    # only; it never trains a model or examines predictions/test performance.
    groups = sorted({a["group"] for a in annotations})
    totals = Counter(a["category"] for a in annotations)
    best = None
    rng = random.Random(20261004)
    for _ in range(12000):
        shuffled = groups.copy(); rng.shuffle(shuffled)
        n = len(groups)
        assignment = {g: "train" if i < round(.7*n) else "validation" if i < round(.85*n) else "test" for i, g in enumerate(shuffled)}
        counts = {s: Counter(a["category"] for a in annotations if assignment[a["group"]] == s) for s in ["train", "validation", "test"]}
        if any(counts[s][c] < (2 if s == "train" else 1) for s in counts for c in CLASSES):
            continue
        score = sum((counts[s][c] - totals[c]*fraction)**2/max(1,totals[c]) for s,fraction in [("train",.7),("validation",.15),("test",.15)] for c in CLASSES)
        if best is None or score < best[0]: best = (score, assignment, counts)
    assert best, "Need independent groups in each class"
    for a in annotations: a["split"] = best[1][a["group"]]
    write(root/"dataset.json", annotations)
    write(root/"split-manifest.json", {"seed":20261004,"algorithm":"grouped-class-counts-v1; no model outcomes", "reviewSha256":sha(args.review), "ocrSha256":sha(args.ocr), "classes":CLASSES,"arrangements":ARRANGEMENTS,"assignment":best[1],"counts":best[2],"humanConfirmed":False,"independentAcceptance":False})
    write(root/"dataset-summary.json", {"samples":len(annotations),"groups":len(groups),"categories":totals,"splits":best[2],"datasetSha256":sha(root/"dataset.json"),"annotationScope":"admission, category, arrangement and OCR evidence; NOT complete numeric-field gold"})
    print(json.dumps(json.loads((root/"dataset-summary.json").read_text()),ensure_ascii=False,indent=2))


if __name__ == "__main__": main()
