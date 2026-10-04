# Qwen 本地截图分类微调

本流程实际微调应用内的 **Qwen3-0.6B-MLX-4bit**，与同目录此前的 RBT3 分类器训练是两个独立实验。原始权重固定为 `Qwen/Qwen3-0.6B-MLX-4bit` 修订 `173234aa840d113125e9f2271100ddbaf16c9620`。只使用本地文件和 MLX QLoRA；没有截图上传、云端调用或自动下载。

## 本轮数据

159 张来自用户 `测试截图` 文件夹的真实截图，助手逐张查看原图与实际 Vision OCR。标签为 82 张收录、76 张跳过、1 张不确定；标签未经用户逐项确认。收录按领取、日程、消费、收藏四组划分，内部细分 8 种页面用途。

本轮在训练前冻结 `qwen_manual_labels_2026_10_04.tsv` 和导出的 `review/annotations.json`。原有相似来源分组及 115/24/20 划分保留；验证和测试样本此前已经在开发实验中查看，**不是独立验收集**。两张空 OCR 图片不进入文字模型训练；一张长表格有两个分段，两段均单独审核了资料依据。

数据和训练权重保存在项目外：

`/Users/ivandrew/Desktop/Sift-Qwen微调-2026-10-04/`

训练输入直接采用 Swift 生产代码导出的完整提示词和 token ID，包括关闭 thinking 的模板、业务区域及本地字段角色线索。不得向输入加入文件名、审核理由、目标标签或人工证据。Python 分词器与导出的 token ID 逐条一致性核对。提示词不参与损失，只监督 `category`、`arrangement` 两个 JSON 值及回答格式；不会训练模型生成标题或数字。

## 训练

- 冻结 4-bit 基础权重，最后 16 层的 q/v 投影使用 rank 8、scale 16 LoRA；训练 655,360 个参数。
- batch 1，累积 2 步，学习率 1e-4，种子 20261004，梯度检查点。
- 训练集中稀少类别最多重复 3 次；重复不是新增真实样本，验证/测试不重复。
- 输入最多 2048 tokens，完整答案保留；默认 360 步，先按最低验证答案损失保存检查点，再比较全部已保存检查点的验证分类宏平均 F1、分组正确数、类别与安排性质匹配数。
- 为降低训练内存，只在答案位置做词表投影；训练前检查结果与官方 masked loss 数值一致。
- 基础模型 SHA 在训练、融合前后复核；候选另存，不能冒用官方基础模型修订。

## 复现

应用内权重已微调，复现必须显式提供项目外的官方原版目录，不能将当前应用权重作为初始基础模型。

在项目根目录，用安装了 `mlx-lm==0.30.2`、`mlx==0.32.3` 的本地 Python 环境运行。不要用普通 chat 数据加载器再次套模板，Qwen 默认 thinking 模板与生产环境不同。

```sh
python Scripts/Training/prepare_qwen_labels.py --run /path/to/run
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release --scratch-path /tmp/SiftVLMEvaluation --product SiftEvaluate
/tmp/SiftVLMEvaluation/out/Products/Release/SiftEvaluate --export-training-inputs --fixtures /path/to/run/fixtures.json --ocr-cache /path/to/run/source-ocr.json --model Sift/Resources/LocalModel --output /path/to/run/production-inputs.json
python Scripts/Training/qwen_finetune.py prepare --run /path/to/run --base /path/to/original-qwen0.6
python Scripts/Training/qwen_finetune.py train --run /path/to/run --base /path/to/original-qwen0.6 --iters 360 --name run-01
python Scripts/Training/fuse_qwen_candidate.py --run /path/to/run --base /path/to/original-qwen0.6
python Scripts/Training/select_qwen_checkpoint.py --run /path/to/run --base /path/to/original-qwen0.6
```

`qwen_finetune.py judge` 可以对原版、LoRA 和融合后的候选运行相同 token 输入的贪心推理。`qwen_compare.py` 分别统计四组＋跳过／不确定准确率、8 类＋安排性质完全匹配率、无关误收、漏收、JSON 异常及回退样例。训练与非训练样本必须分开统计。

Swift 实际受约束生成与原文校验使用 `SiftEvaluate --model-profile qwen-finetuned --candidate-revision <candidate model.safetensors SHA256> --model /path/to/candidate-model`。这是仅在 Mac 上启用的开发评测入口；其他实验候选仍只能走此入口，`--real` 不接受未固定的候选身份。2026-10-04 选定的 v2 产物现已成为应用固定的 `bundled` 模型。

`SiftEvaluate --judge-training-inputs --ocr-cache ...` 使用生产 JSON 约束、关闭 thinking、2048 输入预算、192 输出预算、8-bit KV 和原始提示词，单独衡量场景判断。`qwen_native_compare.py` 将这些真实输出与冻结标签对照。普通 `--images --ocr-cache ...` 另外衡量直接提取、模型和原文校验后的最终收录；两类指标不得混用。

本轮原版在 Python 无约束推理时大量输出不符合协议的 Markdown／英文类别，所以该对照仅用于格式遵从诊断；正式开发对照采用上述 Swift 生产约束。最终候选保存在 `candidate-model-v2`，第 239 步的最低损失候选 `candidate-model` 同样保留，避免覆盖实验结果。

## 边界

分类训练结果不能证明取件码、金额、日期字段完全正确。没有完整数字字段金标准时，不报告关键数字准确率；已有字段校验及人工确认流程继续有效。缓存 OCR 的 Mac 测试不等于完整图片流程、iPhone 推理或飞行模式验收。训练产物不自动部署。2026-10-04 用户已明确要求采用比原版表现更好的版本，现已将 `candidate-model-v2` 纳入应用；构建与手机安装结果见 `Evaluation/results/2026-10-04-qwen-finetune-deployment.md`。

参考：[MLX LM 官方 QLoRA 说明](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md)、[Qwen 原始模型](https://huggingface.co/Qwen/Qwen3-0.6B-MLX-4bit)。
