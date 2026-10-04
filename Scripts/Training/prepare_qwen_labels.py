#!/usr/bin/env python3
"""Freeze individually reviewed screenshot decisions; no model predictions are labels."""
import argparse
import collections
import hashlib
import html
import json
from pathlib import Path

LABELS = {
    "N": ("无关", "无", None), "U": ("不确定", "无", None),
    "P": ("领取通知", "无", "取货码／取件码"),
    "A": ("明确安排", "通知", "日程／预约／出行"),
    "T": ("明确安排", "行程", "日程／预约／出行"),
    "R": ("明确安排", "确认", "日程／预约／出行"),
    "F": ("付款凭证", "无", "消费／订单／凭证"),
    "O": ("已有订单", "无", "消费／订单／凭证"),
    "V": ("其他凭证", "无", "消费／订单／凭证"),
    "C": ("参考收藏", "参考", "资料／地点／灵感收藏"),
}

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def write(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--labels", type=Path, default=Path(__file__).with_name("qwen_manual_labels_2026_10_04.tsv"))
    args = parser.parse_args()
    original = json.loads((args.run / "source-annotations.json").read_text())
    ocr = json.loads((args.run / "source-ocr.json").read_text())
    rows = [line.split("\t", 2) for line in args.labels.read_text().splitlines() if line.strip()]
    assert len(rows) == len(original) == 159
    annotated, fixtures, changes = [], [], []
    for number, (source, row) in enumerate(zip(original, rows), 1):
        index, code, reason = row
        assert int(index) == number and code in LABELS and reason
        assert sha(source["image"]) == source["sha256"], source["id"]
        category, arrangement, group = LABELS[code]
        item = {k: source[k] for k in ("id", "image", "sha256", "split", "group")}
        item.update(category=category, arrangement=arrangement, fourGroup=group,
                    admission="uncertain" if code == "U" else "skip" if code == "N" else "include",
                    reason=reason, reviewer="Codex assistant — original image and Vision OCR reviewed",
                    humanConfirmed=False, independentAcceptance=False, reviewedAt="2026-10-04",
                    numericGoldComplete=False, labelCode=code, contactSheet=(number-1)//16+1,
                    trainingInput="Vision OCR only; original images reviewed for labels, not fed to Qwen",
                    requiresReview=code == "U" or any(v in reason for v in ("需确认", "需核对", "缺失", "多场", "多个独立", "多个本人", "待核查")))
        annotated.append(item)
        allowed = {"P": ["delivery", "pickup"], "A": ["event", "health"], "T": ["event", "health"],
                   "R": ["event", "health"], "F": ["payment", "shopping", "documentation"],
                   "O": ["payment", "shopping", "documentation"], "V": ["payment", "shopping", "documentation"],
                   "C": ["learning", "technical", "place", "inspiration"]}.get(code, [])
        fixtures.append(dict(id=item["id"], origin="assistant-reviewed-real-screenshot", lines=[],
                             accepted=code not in ("N", "U"), allowedCategories=allowed, numeric={},
                             image=item["image"], sha256=item["sha256"], reviewer=item["reviewer"],
                             reviewedAt=item["reviewedAt"], expectedFailure=code == "U"))
        old = source["category"]
        current = "ignored" if code == "N" else "uncertain" if code == "U" else "pickup" if code == "P" else "schedule" if code in "ATR" else "commerce" if code in "FOV" else "collection"
        if old != current:
            changes.append(dict(id=item["id"], previous=old, revised=current, reason=reason))
    # Freeze the old split and explicitly disclose prior exposure; no independent test claim.
    groups = collections.defaultdict(set)
    for row in annotated:
        groups[row["group"]].add(row["split"])
    assert all(len(v) == 1 for v in groups.values()), "Source group crosses splits"
    review = args.run / "review"
    review.mkdir(exist_ok=True)
    labels_path = review / "annotations.json"
    if labels_path.exists():
        assert json.loads(labels_path.read_text()) == annotated, "Frozen labels cannot be overwritten"
    else:
        write(labels_path, annotated)
    write(args.run / "fixtures.json", fixtures)
    manifest = dict(labelSha256=sha(labels_path), manualSourceSha256=sha(args.labels),
                    ocrSha256=sha(args.run/"source-ocr.json"), count=len(annotated),
                    categories=dict(collections.Counter(r["category"] for r in annotated)),
                    admissions=dict(collections.Counter(r["admission"] for r in annotated)),
                    splits={s: dict(collections.Counter(r["category"] for r in annotated if r["split"] == s)) for s in ("train", "validation", "test")},
                    splitPolicy="Existing 115/24/20 source-group split preserved. Validation and test were observed in earlier experiments; both are development holdouts, not independent acceptance.",
                    independentAcceptance=False, humanConfirmed=False,
                    emptyOCR=[r["id"] for r in annotated if not ocr[r["id"]]["rawText"].strip()],
                    numericTraining=False, revisedCategories=changes)
    write(args.run / "label-manifest.json", manifest)
    cards = []
    for i, r in enumerate(annotated, 1):
        escape = html.escape
        source = Path(r["image"]).as_uri()
        cards.append(f'<article data-label="{escape(r["admission"])}"><a href="{source}"><img loading="lazy" src="{source}" alt="截图 {i}"></a><section><h2>{i}. {escape(r["id"])}</h2><b>{escape(r["admission"])} · {escape(r["category"])} · {escape(r["arrangement"])}</b><p>{escape(r["reason"])}</p><small>{escape(r["split"])} · {escape(r["group"])}</small><details><summary>原文 OCR</summary><pre>{escape(ocr[r["id"]]["rawText"])}</pre></details></section></article>')
    header = '<!doctype html><meta charset="utf-8"><title>Sift 截图标注</title><style>body{font:16px system-ui;background:#f5f4ef;max-width:1000px;margin:40px auto;padding:20px}article{display:flex;background:white;padding:18px;gap:24px;margin:20px 0;border-radius:18px}img{width:190px;max-height:420px;object-fit:contain}section{flex:1}pre{white-space:pre-wrap;font-size:12px}small{color:#666}b{background:#ffe500;padding:5px}</style><h1>159 张真实截图 · 收录与分类标注</h1><p>由助手逐张查看原图和 OCR 标注，未经用户确认。歧义标为不确定。训练、验证、测试均为开发样本，不构成独立验收。点击图片查看原图；全部数据仅存本地。</p>'
    (review/"标注查看.html").write_text(header+"\n".join(cards))
    print(json.dumps({k: manifest[k] for k in ("count", "categories", "admissions", "splits", "emptyOCR")}, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
