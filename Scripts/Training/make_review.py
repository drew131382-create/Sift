"""Create a local visual label review and Swift grounding fixtures.

Numeric labels are copied only as partial regression anchors. They do not become
complete field gold and are not eligible for formal numeric-accuracy claims.
"""
import argparse
import csv
import html
import json
from pathlib import Path

from PIL import Image
from train_classifier import write

GROUP_LABELS={"ignored":"跳过","pickup":"取货码／取件码","schedule":"日程／预约／出行","commerce":"消费／订单／凭证","collection":"资料／地点／灵感收藏"}
ALLOWED={"pickup":["pickup","delivery"],"schedule":["event","health"],"commerce":["payment","shopping","documentation"],"collection":["learning","place","technical","inspiration"]}


def main():
    ap=argparse.ArgumentParser();ap.add_argument("--dataset",required=True);ap.add_argument("--prior",required=True);ap.add_argument("--output",required=True)
    args=ap.parse_args();root=Path(args.output);root.mkdir(parents=True,exist_ok=True);thumbs=root/"thumbnails";thumbs.mkdir(exist_ok=True)
    rows=json.loads(Path(args.dataset).read_text());prior={r["id"]:r for r in json.loads(Path(args.prior).read_text())}
    fixtures=[];cards=[]
    with (root/"labels.csv").open("w",newline="") as f:
        writer=csv.writer(f);writer.writerow(["id","category","arrangement","split","group","evidenceBlocks","evidenceText","reason","reviewer","humanConfirmed","sha256"])
        for r in rows:
            evidence=[r["document"]["blocks"][i]["text"] for i in r["evidenceBlocks"]]
            writer.writerow([r["id"],r["category"],r["arrangement"],r["split"],r["group"],json.dumps(r["evidenceBlocks"])," | ".join(evidence),r["reason"],r["reviewer"],False,r["sha256"]])
            source=prior[r["id"]]
            fixture={"id":r["id"],"origin":"assistant-reviewed-real-screenshot","image":r["image"],"sha256":r["sha256"],"lines":[],"accepted":r["category"]!="ignored","numeric":source.get("numeric",{}) if r["category"]!="ignored" else {},"reviewedAt":r["reviewedAt"],"reviewer":r["reviewer"]}
            if fixture["accepted"]: fixture["allowedCategories"]=ALLOWED[r["category"]]
            for key in ["forbidden","allowedNumeric"]:
                if key in source:fixture[key]=source[key]
            if r["id"]=="IMG_0604.PNG":
                fixture["numeric"].pop("code",None);fixture.setdefault("forbidden",{})["code"]=["35664"]
            if r["id"] in ["IMG_5870.PNG","IMG_5944.PNG"]:
                fixture["numeric"].pop("amount",None);fixture.setdefault("forbidden",{})["amount"]=["6.71" if r["id"]=="IMG_5870.PNG" else "4.9"]
            fixtures.append(fixture)
            with Image.open(r["image"]) as im:
                im=im.convert("RGB");im.thumbnail((300,480));im.save(thumbs/(r["id"]+".jpg"),quality=82)
            ocr="\n".join(f'[{i}] {b["text"]}' for i,b in enumerate(r["document"]["blocks"]))
            esc=html.escape
            cards.append(f'<article data-category="{r["category"]}" data-split="{r["split"]}"><a href="{esc(r["image"],quote=True)}"><img loading="lazy" src="thumbnails/{esc(r["id"])}.jpg"></a><h2>{esc(r["id"])}</h2><b>{GROUP_LABELS[r["category"]]}</b><p>{r["arrangement"]} · {r["split"]} · {esc(r["group"])}</p><p>{esc(r["reason"])}</p><small>依据：{esc(" | ".join(evidence))}</small><details><summary>OCR 块与位置编号</summary><pre>{esc(ocr)}</pre></details></article>')
    write(root/"grounding-fixtures.json",fixtures)
    page='''<!doctype html><html lang="zh"><meta charset="utf-8"><title>Sift 本地截图标注</title><style>body{font:15px system-ui;margin:24px;background:#f6f5f1;color:#171717}header{position:sticky;top:0;background:#f6f5f1;padding:8px 0 16px;z-index:2}h1{font-size:25px}b{background:#ffe600;padding:5px 9px;border-radius:6px}main{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:18px}article{background:white;border-radius:18px;padding:18px;border:1px solid #e5e5e5}img{height:300px;max-width:100%;object-fit:contain;display:block;margin:auto}h2{font-size:17px}pre{white-space:pre-wrap;font-size:12px}small{color:#555}select{padding:8px;border-radius:7px}article[hidden]{display:none}</style><header><h1>159 张截图 · 助手审核标注</h1><p>不是人工确认的金标准。点击图片查看原图。标签与分组在训练前冻结；训练结果不会自动修改标签。</p><select id="category"><option value="">所有类别</option>'''
    page+=''.join(f'<option value="{c}">{name}</option>' for c,name in GROUP_LABELS.items())
    page+='</select> <select id="split"><option value="">全部分组</option><option>train</option><option>validation</option><option>test</option></select></header><main>'+''.join(cards)+'''</main><script>function filter(){let c=document.getElementById('category').value,s=document.getElementById('split').value;document.querySelectorAll('article').forEach(a=>a.hidden=!!((c&&a.dataset.category!==c)||(s&&a.dataset.split!==s)))}document.querySelectorAll('select').forEach(s=>s.onchange=filter)</script></html>'''
    (root/"标注查看.html").write_text(page)
    print("Local review and partial-field fixtures written:",root)


if __name__=="__main__":main()
