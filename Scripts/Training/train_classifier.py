"""Offline, document-level supervised fine tuning of a small Chinese encoder.

Every OCR token is covered by overlapping windows. Splits are immutable and
selected before training. Evidence, filenames, labels and reviewer explanations
are NEVER input features. Test data is evaluated once after checkpoint selection.
"""
import argparse
import hashlib
import json
import random
import time
from collections import Counter
from pathlib import Path

import numpy as np
import torch
from sklearn.metrics import classification_report, confusion_matrix, f1_score
from transformers import AutoConfig, AutoModel, AutoTokenizer

CLASSES = ["ignored", "pickup", "schedule", "commerce", "collection"]
SCHEDULE_KINDS = ["confirmed", "travel", "notice"]
LENGTH = 256
STRIDE = 192


def write(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def encode_document(document, tokenizer):
    # Vision coordinates use a bottom-left origin. Stable reading bands avoid
    # non-transitive approximate-y comparators; every OCR block is preserved.
    def key(pair):
        i,b = pair; (x,y),(w,h) = b["boundingBox"]
        return (-round((y+h/2)/.015), x, i)
    ids, boxes = [], []
    for _,block in sorted(enumerate(document["blocks"]), key=key):
        (x,y),(w,h) = block["boundingBox"]
        geometry = [x, 1-y-h, x+w, 1-y, block["confidence"]]
        tokens = tokenizer.encode(block["text"], add_special_tokens=False)
        ids.extend(tokens + [tokenizer.sep_token_id])
        boxes.extend([geometry] * (len(tokens)+1))
    if not ids: ids, boxes = [tokenizer.sep_token_id], [[0.]*5]
    windows=[]
    for start in range(0,len(ids),STRIDE):
        tokens=[tokenizer.cls_token_id]+ids[start:start+LENGTH-2]+[tokenizer.sep_token_id]
        geom=[[0.]*5]+boxes[start:start+LENGTH-2]+[[0.]*5]
        mask=[1]*len(tokens); padding=LENGTH-len(tokens)
        windows.append((tokens+[tokenizer.pad_token_id]*padding,mask+[0]*padding,geom+[[0.]*5]*padding))
        if start+LENGTH-2 >= len(ids): break
    return {"input_ids":torch.tensor([w[0] for w in windows],dtype=torch.long),
            "attention_mask":torch.tensor([w[1] for w in windows],dtype=torch.long),
            "geometry":torch.tensor([w[2] for w in windows],dtype=torch.float32),
            "tokens":len(ids),"windows":len(windows)}


class ScreenshotClassifier(torch.nn.Module):
    def __init__(self, base_directory, pretrained=True):
        super().__init__()
        config=AutoConfig.from_pretrained(base_directory,local_files_only=True)
        config._attn_implementation="eager"
        if pretrained:
            self.encoder=AutoModel.from_pretrained(base_directory,config=config,local_files_only=True,add_pooling_layer=False)
        else: self.encoder=AutoModel.from_config(config,add_pooling_layer=False)
        hidden=config.hidden_size
        self.layout=torch.nn.Linear(5,hidden,bias=False)
        torch.nn.init.zeros_(self.layout.weight)
        self.dropout=torch.nn.Dropout(.2)
        self.category=torch.nn.Linear(hidden,len(CLASSES))
        self.arrangement=torch.nn.Linear(hidden,len(SCHEDULE_KINDS))

    def forward(self,input_ids,attention_mask,geometry):
        embedded=self.encoder.embeddings.word_embeddings(input_ids)+self.layout(geometry)
        h=self.encoder(inputs_embeds=embedded,attention_mask=attention_mask,return_dict=False)[0]
        mask=attention_mask.unsqueeze(-1).to(h.dtype)
        pooled=(h*mask).sum(dim=1)/mask.sum(dim=1).clamp(min=1)
        pooled=self.dropout(pooled)
        return self.category(pooled),self.arrangement(pooled)


def document_logits(model, features, device):
    # Serial window batches limit memory while still reading the whole screenshot.
    outputs=[]; arrangements=[]
    for i in range(0,features["windows"],8):
        kwargs={k:features[k][i:i+8].to(device) for k in ["input_ids","attention_mask","geometry"]}
        cat,arr=model(**kwargs); outputs.append(cat);arrangements.append(arr)
    return torch.cat(outputs).mean(0),torch.cat(arrangements).mean(0)


def evaluate(model, rows, features, device):
    model.eval(); predictions=[]
    with torch.inference_mode():
        for row in rows:
            start=time.perf_counter()
            logits,arr=document_logits(model,features[row["id"]],device)
            if device=="mps": torch.mps.synchronize()
            probabilities=torch.softmax(logits,dim=-1).cpu().numpy()
            label=int(np.argmax(probabilities))
            kind=SCHEDULE_KINDS[int(arr.argmax())] if label==2 else "reference" if label==4 else "none"
            predictions.append({"id":row["id"],"split":row["split"],"expected":row["category"],"predicted":CLASSES[label],"expectedArrangement":row["arrangement"],"arrangement":kind,"probabilities":probabilities.tolist(),"logits":logits.cpu().tolist(),"arrangementLogits":arr.cpu().tolist(),"seconds":time.perf_counter()-start,"windows":features[row["id"]]["windows"]})
    truth=[CLASSES.index(p["expected"]) for p in predictions];pred=[CLASSES.index(p["predicted"]) for p in predictions]
    report=classification_report(truth,pred,labels=list(range(5)),target_names=CLASSES,zero_division=0,output_dict=True)
    tp=sum(p["expected"]!="ignored" and p["predicted"]!="ignored" for p in predictions)
    fp=sum(p["expected"]=="ignored" and p["predicted"]!="ignored" for p in predictions)
    fn=sum(p["expected"]!="ignored" and p["predicted"]=="ignored" for p in predictions)
    tn=sum(p["expected"]=="ignored" and p["predicted"]=="ignored" for p in predictions)
    metrics={"samples":len(rows),"classification":report,"macroF1":f1_score(truth,pred,labels=list(range(5)),average="macro",zero_division=0),"confusionMatrix":confusion_matrix(truth,pred,labels=list(range(5))).tolist(),"admission":{"tp":tp,"fp":fp,"fn":fn,"tn":tn,"precision":tp/max(1,tp+fp),"recall":tp/max(1,tp+fn)},"scheduleNatureCorrect":sum(p["expectedArrangement"]==p["arrangement"] for p in predictions if p["expected"]=="schedule"),"scheduleNatureTotal":sum(p["expected"]=="schedule" for p in predictions)}
    return predictions,metrics


def main():
    ap=argparse.ArgumentParser();ap.add_argument("--dataset",required=True);ap.add_argument("--base",required=True);ap.add_argument("--output",required=True)
    ap.add_argument("--epochs",type=int,default=36);ap.add_argument("--seed",type=int,default=20261004);ap.add_argument("--device",default="mps")
    ap.add_argument("--test-already-observed",action="store_true",help="Disclose reuse; scores are then regression diagnostics, not a fresh holdout")
    args=ap.parse_args();root=Path(args.output);root.mkdir(parents=True,exist_ok=True)
    assert not (root/"heldout-metrics.json").exists(), "Never tune/retrain over an already inspected test run; use a new experiment and disclose reuse"
    random.seed(args.seed);np.random.seed(args.seed);torch.manual_seed(args.seed);torch.set_num_threads(6)
    if args.device=="mps": assert torch.backends.mps.is_available()
    rows=json.loads(Path(args.dataset).read_text())
    bysplit={s:[r for r in rows if r["split"]==s] for s in ["train","validation","test"]}
    assert all(bysplit.values())
    assert len({r["group"] for r in rows})==sum(len({r["group"] for r in bysplit[s]}) for s in bysplit)
    tokenizer=AutoTokenizer.from_pretrained(args.base,local_files_only=True,use_fast=True)
    features={r["id"]:encode_document(r["document"],tokenizer) for r in rows}
    write(root/"input-coverage.json",{i:{"tokens":f["tokens"],"windows":f["windows"],"allBlocksCovered":True} for i,f in features.items()})
    model=ScreenshotClassifier(args.base).to(args.device)
    counts=Counter(r["category"] for r in bysplit["train"])
    class_weights=torch.tensor([np.sqrt(len(bysplit["train"])/(5*counts[c])) for c in CLASSES],dtype=torch.float32,device=args.device)
    # Per-document training: reduction='mean' would divide by the lone target's
    # weight and cancel class balancing. Sum preserves the explicit weights.
    lossfn=torch.nn.CrossEntropyLoss(weight=class_weights,label_smoothing=.03,reduction="sum")
    optimizer=torch.optim.AdamW([{"params":model.encoder.parameters(),"lr":2e-5},{"params":model.layout.parameters(),"lr":2e-4},{"params":list(model.category.parameters())+list(model.arrangement.parameters()),"lr":5e-4}],weight_decay=.01)
    initial=model.category.weight.detach().cpu().clone()
    write(root/"configuration.json",{"base":"hfl/rbt3","revision":"0aa0527ff4170f29e1dfd3eb6ef60dc67e1bf75c","datasetSha256":digest(args.dataset),"seed":args.seed,"sequenceLength":LENGTH,"stride":STRIDE,"classes":CLASSES,"scheduleKinds":SCHEDULE_KINDS,"parameterCount":sum(p.numel() for p in model.parameters()),"device":args.device,"epochsLimit":args.epochs,"batchDocuments":4,"selection":"validation macro F1; tie by lower validation loss; patience 12","lossReduction":"sum; preserve per-document class weights","classWeights":class_weights.cpu().tolist(),"allOCRCovered":True,"humanGold":False,"testAlreadyObserved":args.test_already_observed,"independentAcceptance":False})
    history=[];best=(-1,float("inf"));stale=0;started=time.perf_counter()
    for epoch in range(1,args.epochs+1):
        model.train();train=bysplit["train"].copy();random.shuffle(train);losses=[]
        optimizer.zero_grad(set_to_none=True)
        for i,row in enumerate(train):
            logits,arr=document_logits(model,features[row["id"]],args.device)
            y=torch.tensor([CLASSES.index(row["category"])],device=args.device)
            loss=lossfn(logits.unsqueeze(0),y)
            if row["category"]=="schedule":
                loss=loss+.25*torch.nn.functional.cross_entropy(arr.unsqueeze(0),torch.tensor([SCHEDULE_KINDS.index(row["arrangement"])],device=args.device))
            # Divide by actual final minibatch size as well as normal batches.
            batch_size=min(4,len(train)-(i//4)*4)
            (loss/batch_size).backward();losses.append(float(loss.detach().cpu()))
            if (i+1)%4==0 or i+1==len(train):
                torch.nn.utils.clip_grad_norm_(model.parameters(),1.0);optimizer.step();optimizer.zero_grad(set_to_none=True)
        predictions,metrics=evaluate(model,bysplit["validation"],features,args.device)
        val_loss=float(np.mean([-np.log(max(1e-9,p["probabilities"][CLASSES.index(p["expected"])])) for p in predictions]))
        score=(metrics["macroF1"],-val_loss)
        entry={"epoch":epoch,"trainLoss":float(np.mean(losses)),"validationLoss":val_loss,"validationMacroF1":score[0],"validationAccuracy":sum(p["expected"]==p["predicted"] for p in predictions)/len(predictions),"validationAdmission":metrics["admission"],"elapsedSeconds":time.perf_counter()-started}
        history.append(entry);write(root/"history.json",history);print(json.dumps(entry),flush=True)
        if score>(best[0],-best[1]):
            best=(score[0],val_loss);stale=0
            torch.save({"state_dict":{k:v.detach().cpu() for k,v in model.state_dict().items()},"epoch":epoch},root/"best.pt")
            write(root/"selected-validation-predictions.json",predictions)
        else: stale+=1
        if stale>=12: break
    checkpoint=torch.load(root/"best.pt",map_location="cpu",weights_only=True);model.load_state_dict(checkpoint["state_dict"])
    changed=float((model.category.weight.detach().cpu()-initial).abs().max())
    assert changed>0, "Training must actually update weights"
    reports={};all_predictions=[]
    # Only now is the fixed test partition read for scoring.
    for split in ["train","validation","test"]:
        predictions,metrics=evaluate(model,bysplit[split],features,args.device)
        write(root/(split+"-predictions.json"),predictions);reports[split]=metrics;all_predictions.extend(predictions)
    write(root/"predictions.json",all_predictions)
    write(root/"heldout-metrics.json",{"selectedEpoch":checkpoint["epoch"],"maximumHeadWeightChange":changed,"trainingSeconds":time.perf_counter()-started,"splits":reports,"testEvaluationsThisRun":1,"testAlreadyObserved":args.test_already_observed,"testThresholdTuning":False,"humanConfirmed":False,"independentAcceptance":False})
    tokenizer.save_pretrained(root/"tokenizer")
    print("TRAINING COMPLETE",json.dumps(reports["test"],ensure_ascii=False),flush=True)


if __name__=="__main__": main()
