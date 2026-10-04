# 本地截图分类训练

Qwen 的实际 QLoRA 微调另见 [README_QWEN.md](README_QWEN.md)，与下面的 RBT3 实验分开保存和评估。

此工具训练独立的 **OCR＋版面分类模型**，不是微调 Qwen，也不是 VLM。模型判断跳过、领取、日程、消费、收藏，另判断日程的确认／行程／行动通知性质。字段、标题和证据仍交给现有原文关联与校验。

## 当前产物

2026-10-04 的原图、标注、OCR、训练权重及查看页均保存在项目外：

`/Users/ivandrew/Desktop/Sift训练-2026-10-04/`

- `review/annotations.json`：159 张原图逐项标注，包括理由、OCR 依据、来源校验和相似页面分组。
- `review/annotation-corrections.json`：训练前相对旧临时标注的调整；原标注文件未覆盖。
- `review/标注查看.html`、`review/labels.csv`：本地查看与复核。
- `dataset/dataset.json`、`split-manifest.json`：冻结的 115／24／20 分组。
- `run-01/`：首次实验，记录类别加权损失在逐张计算时被归一化抵消的问题。
- `run-02-balanced/`：修正后的训练，按验证集宏平均 F1 选择第 4 轮权重；测试分组的重复使用已披露。
- `run-02-balanced/SiftScreenshotClassifier.mlpackage`：约 75.8 MB 的 Core ML 开发候选。
- `run-02-balanced/SiftScreenshotClassifier.mlmodelc`：**Mac 编译检查产物**，不能直接拿它替代 iPhone 构建；iPhone 应从 `.mlpackage` 编译。

所有标签为助手审核，未经用户逐项确认。数字字段仅有部分既有回归锚点，尚未完成完整字段金标准。训练集和既有开发数据不能冒充独立验收集。

## 训练约束

基础模型为 [HFL RBT3](https://huggingface.co/hfl/rbt3)，固定修订 `0aa0527ff4170f29e1dfd3eb6ef60dc67e1bf75c`，3 层中文编码器，训练网络 37,896,200 个参数。保留 Apache 2.0 许可与来源说明。

- 输入只有 Vision OCR 原文、阅读顺序、归一化位置及 OCR 置信度；没有截图文件名、审核理由、人工证据编号、目标标签或 Qwen 输出。
- 不按关键词先删除未知页面；所有 OCR 块进入编码。256 token 窗口、192 token 步长覆盖完整长图，窗口 logits 求平均。
- 图片不作为网络输入。数据不上传；资源下载只在开发阶段进行。训练、分词、导出和验证均使用本地资源。
- 训练前按相似页面／同一业务来源分组；训练、验证、测试没有共享 group 或相同原图 SHA。
- 验证集选 checkpoint，不按测试集调阈值或修改标签。若测试已看过，后续实验必须加 `--test-already-observed`，成绩按开发回归报告。
- 默认全编码器微调，串行文档计算、每 4 张累积更新；类别加权损失使用 `sum`，保留每张权重。日程性质仅对日程样本监督。
- 此监督分类模型未达到上线标准，应用继续使用 Qwen3-0.6B，尚未使用此监督分类器。Core ML 使用 ALL 计算单元，不证明实际驻留 ANE，真机耗时与内存尚未测量。

## 重跑

用 Python 3.12 创建独立环境并安装 `requirements.txt`，不要修改应用运行依赖。以下变量均替换为实际本地目录。`prepare_dataset.py` 拒绝覆盖冻结数据；新标注必须用新版本目录。

```sh
python Scripts/Training/prepare_base.py --output /path/to/base-rbt3
python Scripts/Training/prepare_dataset.py \
  --review /path/to/assistant-reviewed-annotations.json \
  --ocr /path/to/vision-ocr.json --output /path/to/dataset-v2
python Scripts/Training/train_classifier.py \
  --dataset /path/to/dataset-v2/dataset.json --base /path/to/base-rbt3 \
  --output /path/to/run --epochs 36
python Scripts/Training/export_coreml.py \
  --dataset /path/to/dataset-v2/dataset.json --base /path/to/base-rbt3 --run /path/to/run
python Scripts/Training/validate_artifacts.py \
  --dataset /path/to/dataset-v2/dataset.json --base /path/to/base-rbt3 --run /path/to/run
```

已有测试分组被查看过时，训练命令额外传入 `--test-already-observed`。不能把重新切分同一批数据当作新独立验收。

`export_coreml.py` 实际执行 Core ML 本地预测，并核对全部样本与 PyTorch 的类别及安排性质一致性。`validate_artifacts.py` 检查原图、分组、完整长文覆盖、编码器真实权重变化和 Mac 编译。

## 与现有建卡逻辑比较

`make_review.py` 导出 `grounding-fixtures.json`。Swift 评测器新增仅开发使用的 `--classifier-judgments`，读取实际 Core ML 判断后运行当前直接提取及原文校验。

```sh
SiftEvaluate --images --fixtures /path/to/grounding-fixtures.json \
  --ocr-cache /path/to/vision-ocr.json \
  --classifier-judgments /path/to/run/coreml-judgments.json \
  --output /path/to/run/grounding-results.json
```

这是已校验原图 SHA 的 **OCR 缓存与建卡诊断**，没有在 Swift 中运行分类模型，也没有重新 OCR；模型推理在 Python/Core ML 导出验证中另测。正式 `--real` 禁止此导入入口，不能把拼接的耗时报告成 iPhone 完整流程成绩。

当前结果和边界见 `Evaluation/results/2026-10-04-training-report.md`。
