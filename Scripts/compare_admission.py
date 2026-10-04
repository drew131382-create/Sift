#!/usr/bin/env python3
"""Compare admission on fixed labels; errors never count as successful skips.

Use for development diagnostics, including an unlabelled baseline run scored
later against independently reviewed labels. This does not certify human gold.
"""
import argparse
import json
from pathlib import Path


def summarize(labels, results):
    gold = {row["id"]: row for row in labels}
    rows = [row for row in results if row["id"] in gold]
    counts = dict(samples=len(rows), expectedUseful=sum(gold[r["id"]]["accepted"] for r in rows),
                  admitted=0, usefulAdmitted=0, unrelatedAdmitted=0,
                  usefulMissed=0, unrelatedSkipped=0, failures=0, wrongCategory=0,
                  decisionCorrect=0)
    failures, false_positives, missed = [], [], []
    for row in rows:
        label = gold[row["id"]]
        actual, expected = row["accepted"], label["accepted"]
        allowed = label.get("allowedCategories") or ([label["category"]] if label.get("category") else None)
        category_ok = not actual or not allowed or row.get("category") in allowed
        if row.get("error"):
            counts["failures"] += 1
            failures.append(row["id"])
        elif not actual and not expected:
            counts["unrelatedSkipped"] += 1
        if actual:
            counts["admitted"] += 1
            if expected:
                counts["usefulAdmitted"] += 1
                counts["wrongCategory"] += not category_ok
            else:
                counts["unrelatedAdmitted"] += 1
                false_positives.append(row["id"])
        elif expected:
            counts["usefulMissed"] += 1
            missed.append(row["id"])
        expected_error = label.get("expectedFailure") is True and row.get("errorKind") == "invalidOutput"
        counts["decisionCorrect"] += bool((expected_error or not row.get("error")) and actual == expected and category_ok
                                          and (label.get("expectedReview") is None or label["expectedReview"] == (row.get("state") == "needsReview")))
    counts["admissionPrecision"] = counts["usefulAdmitted"] / counts["admitted"] if counts["admitted"] else None
    counts["admissionRecall"] = counts["usefulAdmitted"] / counts["expectedUseful"] if counts["expectedUseful"] else None
    counts.update(falsePositiveIDs=false_positives, missedIDs=missed, failureIDs=failures,
                  annotationOrigins=sorted({r["origin"] for r in labels}), formalAcceptance=False)
    return counts


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("labels", type=Path)
    parser.add_argument("results", nargs="+", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    labels = json.loads(args.labels.read_text())
    output = {str(path): summarize(labels, json.loads(path.read_text())) for path in args.results}
    serialized = json.dumps(output, ensure_ascii=False, indent=2)
    if args.output:
        args.output.write_text(serialized + "\n")
    else:
        print(serialized)
