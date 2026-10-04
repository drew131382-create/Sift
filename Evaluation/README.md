# 本地理解评测

## 样本与验收

当前使用`Qwen/Qwen3-0.6B-MLX-4bit`固定修订`173234aa840d113125e9f2271100ddbaf16c9620`。模型仅判断类别和安排性质；本地代码关联字段与原文依据。旧字段选择流程、LFM及VLM结果均保留为历史对照，不能当作当前成绩。

`synthetic_cases.json`包含60个程序生成的文字样例，用于定位模型问题。它们不是截图、不是人工标注集，不满足真实样本验收要求。单元测试使用人为构造的模型输出，不能证明模型的理解准确率。

`schedule_cases.json`包含22个合成文字回归样例，覆盖日程提问、未确认邀约、设想、待定、取消、新闻/订单/状态栏日期、明确会议、预约详情、无标签复诊、已出票交通、酒店预订、缺失/冲突时间、相邻准备问题，以及海报、营业时间、取件取餐、消费与资料。此文件不能用于`--real`验收。海报按本次产品约束允许`inspiration`或`place`，两者都在收藏组；通过可选`allowedCategories`限定，不允许模型输出日程后被宽松判分。

正式验收需要至少50张经同意、脱敏的真实中文截图，经人阅读原图标注。覆盖四大类、不同布局、聊天反例、验证码/状态栏/孤立数字、原价优惠余额、字段冲突、多场景和长文。记录标注人、日期，尽可能另找一人复核。生成的测试数据不能改名当作人工样本。

先运行 `python3 Scripts/make_annotation_manifest.py /path/to/screenshots /path/to/labels.json` 创建待标注清单；人工填写每项后，将origin改为human-annotated-screenshot。真实截图不放入公开仓库，评测输出仅留本地。

每条记录格式：

```json
{
  "id": "real-001",
  "origin": "human-annotated-screenshot",
  "image": "screenshots/001.png",
  "reviewer": "人工标注人姓名或代号",
  "reviewedAt": "2026-10-02",
  "lines": [],
  "accepted": true,
  "category": "delivery",
  "numeric": {"code": "8-3021"},
  "expectedFields": [{"kind": "code", "value": "8-3021", "scene": 0}],
  "sha256": "原图文件SHA-256",
  "expectedFailure": false,
  "expectedReview": false,
  "forbidden": {"code": ["123456"], "amount": ["100.00", "20.00", "500.00"]}
}
```

image可用绝对路径或相对清单的路径；无关截图accepted=false、category=null、numeric={}。category使用底层编码delivery/pickup/event/payment/shopping/documentation/learning/place/technical/inspiration。正式验收以expectedFields完整列表为准，必须标注全部关键数字和日期时间字段，不能只标主卡。scene为从0开始的独立场景序号；相同金额在两个订单中要分别列两项。单位和货币可用unit/currency检查，原文的前导零与时间写法保留原样。numeric保留为旧诊断格式；forbidden按字段标注禁止误填的原文值。冲突值应留空并expectedReview=true。

## 运行

Mac工具使用和iPhone相同的模型、提示词、JSON约束和字段校验。`--images`和正式模式均从图片运行Vision OCR；文字模式用于合成回归。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build --product SiftEvaluate
.build/debug/SiftEvaluate --fixtures Evaluation/synthetic_cases.json --output /tmp/sift-synthetic.json
.build/debug/SiftEvaluate --fixtures Evaluation/schedule_cases.json --output /tmp/sift-schedule.json
.build/debug/SiftEvaluate --images --fixtures /path/to/provisional-labels.json --output /tmp/sift-diagnostic.json
.build/debug/SiftEvaluate --real --fixtures /path/to/labels.json --output /tmp/sift-real.json
```

实际可执行文件位置取决于SwiftPM构建器，使用`swift build --show-bin-path`查询。网络代理只用于开发者依赖解析和固定模型资源准备，应用推理不联网。

`--images`用于小批真实截图诊断，不要求50张，不代表正式验收。每条必须提供image，缺少图片或读取失败不会回退到合成文字。助手审阅标签标记`origin=assistant-reviewed-real-screenshot`，不可冒称人工标注。诊断模式可选`allowedNumeric`列出合法但不强制提取的数值，不能计入必需字段正确数；正式`--real`禁止使用此可选白名单，需完整标注预期数字字段；数字仅忽略空白比较。分类边界和可选值必须在推理前确定，报告还需单独核对四大组、商户、地点、单位和信息实用性。

评测逐条保存结果与耗时、标题、字段和OCR块数量，另写summary.json；图片模式保存ocr.json，包含原文、位置和置信度。上述文件和`--trace`日志可能含个人信息，应存放在仓库之外的本地报告目录。错误按错误计入判断失败，不当作正确跳过。关键字段准确率为正确字段数/(应提取字段数+未经标注的额外数字字段数)，缺失也计错；禁止字段值误填必须为0。正式模式要求至少50张图片、人工信息齐全，不能用--limit缩小样本；未达到90%判断、98%关键字段或出现禁止误填时，进程返回非零状态。

Mac结果不能代替iPhone验收。MLX峰值仅涵盖其分配器，不是整个应用的物理内存。真机单测`SemanticDeviceSmokeTests`用7张生成图片经过Vision和真实模型，验证四类及反例、记录耗时与MLX内存；这也不是人工真实样本集。

## 手机交付

1. 人工真实截图达到目标，并检查具体失败案例。
2. 有效签名构建独立验证版本，不覆盖现有Sift数据。
3. iPhone执行真实模型、停止/恢复/重试、四组与原图缩放测试；测整个进程内存和耗时。
4. 飞行模式下再次识别与看图；iCloud独有照片事先在系统相册下载。
5. 上述验收完成后更新现有Sift。签名或真实样本不足时，保留代码与评测结果，不宣称达标。

本次开发结果将保存在results目录；具体未通过项必须继续记录。

## 日程约束回归

`Tests/ScheduleAdmissionTests.swift`直接构造模型输出，验证模型强行选择日程时仍能被拒绝、跨块字段关系、分块时间标签、低置信度、时间冲突、取消/疑问作用范围、多场景保留、异常重试、无关副本删除及结构化输出兼容。它验证代码约束，不验证模型理解。

Mac真实Qwen推理另通过上述文字集运行，报告与结果见`results/2026-10-03-schedule-report.md`。未提供经人工确认的真实误收截图，因此真实OCR误收回归、iPhone推理及飞行模式验收仍未完成。开发者账号与Background GPU Access签名阻碍真机更新，不能把未签名构建当作已安装。

## 本轮紧凑选择与评测约束

新回归集`grounded_cases.json`为20条合成文字，只用于规则/真实Qwen诊断，不能计入人工真实样本数量。`--model-only`仅用于开发诊断，强制绕过明确场景快捷提取，正式验收禁止。生产路径中明确场景无需模型；分别记录两条路径，不能以强制模型结果替代完整流程结果。

`--ocr-cache /绝对路径/ocr.json`仅用于定位模型问题，逐图验证原图SHA-256，复用先前真实Vision输出；不是新一轮OCR测试，正式验收禁止。完整图片测试需省略此参数。

正式`--real`现在要求：至少50张不同图片，origin、reviewer、reviewedAt齐全，唯一id和原图sha256；每张完整expectedFields（无数字可填[]），全体至少50个关键数字字段。多场景字段逐项匹配，缺失计错、额外计错、错误绑定场景计错，不通过允许可选值提高成绩。禁止字段检查遍历所有独立场景。空白图预期失败可填写expectedFailure=true，仅invalidOutput符合这一预期，模型缺失/超时等其他失败不能冒充正确。

结果含每张path（direct/model/hybrid）、模型调用数、实际输入/输出token数、冷加载标记及耗时。summary按路径统计中位数和P95，并保存MLX分配器峰值。Mac性能不可代替iPhone性能；完整流程seconds包括Vision，路径metrics.seconds从版面分析开始。标题、摘要、参考价和多订单详情仍需查看原图人工评审，类别正确不等于整张卡片准确。

UI自动化通过显式`--ui-fixtures`使用独立临时数据库；正常启动没有样本卡片，Release没有此样本入口。真实截图、OCR和个人信息报告保留在仓库外本地目录。

## 当前场景判断路线

图片模式先从原图执行Vision；当前 Qwen只读取OCR文字、阅读顺序、区域和已核验角色线索，不接收图片或字段选择表。`--model-only --images`强制跳过直接提取，测试场景判断与本地字段校验组合，仅供诊断，不能作为正式验收。

合成文字命令可以执行真实Qwen，但不能冒充真实图片或人工标注。`metrics.inputTokens/outputTokens/modelCalls`记录模型工作量；summary的`modelTask`为`scene-and-arrangement-only`，`modelImageInput`为false。

Qwen 场景路线结果见`results/2026-10-04-scene-report.md`；历史VLM对照见`results/2026-10-03-vlm-report.md`。LFM/VLM实验资源保存在项目外，应用只打包 Qwen3-0.6B，没有云端兜底。2026-10-04已完成独立中文OCR／版面分类模型的监督微调及Core ML导出，见`results/2026-10-04-training-report.md`和`Scripts/Training/README.md`；未将该监督分类器放入应用。正式评测和训练数据必须分开，不能把固定回归样本同时用作训练与独立验收。

## 严格收录诊断

用户选择仅收明确资料、教程、具体地点，以及有完整信息的商品/活动；普通短视频、广告、评论和闲聊跳过。模型继续自主判断场景/无关，合法输出再经原文校验；未知和异常仍是可重试失败。收藏不再仅凭通用词或长段落收录；直播/个人主页/评论/试用付费页的界面证据不能成为收藏内容。点赞数的“万”不是参考价，订单号不是领取码。

新增136张真实截图和旧23张一起复测，助手审阅标签保留在项目外，不冒充人工确认。收录精确率、召回率、分组错误和失败要分开报告；大量拒绝全部截图不能证明产品可用。标题、摘要和全部数字字段仍需完整标注。诊断结果见`results/2026-10-04-keyinfo-report.md`。

## 监督分类模型开发诊断

`--classifier-judgments /path/to/coreml-judgments.json`读取实际Core ML导出的类别／安排性质，运行当前直接提取及原文校验。与`--ocr-cache`联合使用时只复用已校验原图SHA的真实OCR，不重新OCR，也不在Swift中运行模型；不能拿这里的耗时当完整流程耗时。`summary.importedClassifierJudgments=true`、`classifierInferenceMeasuredHere=false`显式记录来源；正式`--real`禁止此入口。

分类头只学习四组和跳过；消费子类型由原文字面标签交给既有验证器确认。模型错误不能通过改变预期标注消除；独立数字字段的完整标注和陌生来源真机验收仍必需。

可用以下脚本在固定标签上重新评分早期未标注基线，原始结果保持不变；错误不会计为正确跳过：

```sh
python3 Scripts/compare_admission.py /path/to/labels-provisional.json /path/to/baseline.json /path/to/candidate.json --output /path/to/admission-comparison.json
```

`--replay-judgments /path/to/outputs.json` 是 Mac 开发工具的纯校验回放：按 id 提供此前实际模型返回的 JSON 字符串数组，必须配合 `--ocr-cache`；重新构造同一分段并检查输出数量、原文和收录逻辑，不进行生成。summary 明确标记 `replayedSemanticJudgments=true`、`cachedVisionOCR=true`、模型调用数为 0、路径为 `validationReplay`。这不是一次新的 Vision/Qwen 推理，其耗时和 MLX 峰值不能作为推理性能。正式 `--real` 禁止回放。校验修改后还应从原图重新运行代表性正反例，分别记录新推理和回放，不能把二者混为全量新模型实测。

## LFM2.5 与 Qwen 固定模型对照

LFM 对照后已恢复 Qwen3-0.6B 4-bit，应用不同时打包实验权重。Mac 工具提供 `--model-profile bundled|lfm2.5|qwen0.6`，默认使用当前内置的 Sift 微调 Qwen。原版 Qwen 和 LFM 对照均需显式传入项目外的模型目录，原版身份不与 `bundled` 混用。两者都核对各自固定 revision 和本地文件哈希。模型身份写入 summary 和卡片规则版本。

```sh
python3 Scripts/prepare_local_model.py --verify-only
python3 Scripts/prepare_local_model.py --profile lfm2.5 --output /private/evaluation/models/lfm
SiftEvaluate --images --model-profile qwen0.6 --model /private/evaluation/models/original-qwen --fixtures /private/evaluation/fixed.json --output /private/evaluation/qwen.json
SiftEvaluate --images --model-profile lfm2.5 --model /private/evaluation/models/lfm --fixtures /private/evaluation/fixed.json --output /private/evaluation/lfm.json
```

固定规则、提示词和标签，分别运行原图/Vision/实际模型路径；直接提取也计入完整流程，但不能把快捷路径成绩归功于模型。数字标签不完整、助手标注及既有开发样本必须披露。正式报告见 `results/2026-10-04-lfm-comparison-report.md`。

`--inspect-model --output /private/evaluation/probe.json` 是 Mac 独立兼容探针：运行三个固定的短文字提示，保存原生对话模板、首词 logits 有限性及无 JSON 约束的输出。它不属于截图准确率评测，也不保存信息卡；不能与 `--real` 联用。用于和 Python MLX 原生推理交叉核对，排查权重、分词器或约束生成适配问题。
