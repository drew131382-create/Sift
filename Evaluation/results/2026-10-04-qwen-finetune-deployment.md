# Sift 微调模型部署记录 · 2026-10-04

## 已完成

用户已将部署标准调整为“同一批开发样本比原模型准确，就更换”。依据冻结的 44 张开发留出样本结果：原版正确 31/44（70.5%），微调 v2 正确 34/44（77.3%）。不改变标签、字段校验、首页准入或人工确认，不将其称为独立准确率验收。

- 应用默认模型：`Qwen3 0.6B · Sift 微调`，身份 `local/Sift-Qwen3-0.6B-QLoRA`。
- 权重 SHA-256 / 固定修订：`7252e5c48ad95c76ed8900027d4df16f49a588ef966d1cef654b6af6db1e5a5a`。
- 应用只包含一个模型，资源共 332,773,080 bytes（约 333 MB）；本次 Debug 真机应用目录共 418,802,278 bytes（约 419 MB），不是压缩 IPA 或 App Store 下载体积。
- 本地资源、构建后模型清单及所有文件 SHA-256 校验通过；代码签名验证通过；真机构建通过。
- 已通过 devicectl 更新当前 iPhone，安装结果为 success；从手机应用列表再次确认 `com.sift.local`、构建号 `2026100401`。
- 同 bundle ID 更新，没有卸载应用、迁移或删除已有卡片。用户修改与旧分类保留；模型修订进入去重版本，仅主动扫描、导入或重试使用新模型。
- 自动打开应用被 iPhone 锁屏阻止，解锁后可自行打开；没有将安装成功表述为真机推理验收。
- 原版权重备份保留在项目外，已复核原始 SHA-256；融合产物、冻结标签和既有训练结果未覆盖。

## 签名与后台限制

标准 GPU 构建仍因 Xcode 未登录开发者账号、当前描述文件不含 Background GPU Access entitlement 失败。为完成用户授权的模型更新，本次使用独立 `SiftForeground.entitlements` 及 `SIFT_BACKGROUND_GPU_ENABLED=false` 构建前台版本，沿用现有有效证书与设备描述文件。

应用在申请后台扫描前检查该构建标记，明确提示“当前安装版本未获后台 GPU 签名授权，离开应用时会保存进度。”不以普通后台时间执行 MLX。返回前台后仍可继续扫描。标准 `Sift.entitlements` 和默认 GPU 功能保留；完成账号与后台 GPU 授权后可重新构建完整版本。

## 复现构建

```sh
python3 Scripts/prepare_local_model.py --source /Users/ivandrew/Desktop/Sift-Qwen微调-2026-10-04/candidate-model-v2
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project Sift.xcodeproj -scheme Sift -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/SiftLocalAI3 -disableAutomaticPackageResolution -jobs 3 \
  DEVELOPMENT_TEAM=9SGSV6WA66 \
  SIFT_ENTITLEMENTS_PATH=Sift/SiftForeground.entitlements \
  SIFT_BACKGROUND_GPU_ENABLED=false CURRENT_PROJECT_VERSION=2026100401
```

资源准备只复制本地固定融合产物；构建前自动校验，应用继续只从本地目录加载，没有模型下载或云端接口。Mac 评测默认 `bundled`，原版 `qwen0.6` 身份显式保留，比较时必须提供项目外原版目录，不能将新模型冒充旧基线。

## 验证边界

本次执行了构建、资源校验、签名校验、安装及手机安装版本核对，没有重新运行训练／回归测试。既有准确率来自训练对照报告。手机当前锁定，未执行新一轮真机识别、飞行模式、耗时、内存或后台验收。模型资源几乎保持原体积，仍为 4-bit 文本模型；不是多模态模型，也不保证所有字段完全正确。

详见 [机器记录](2026-10-04-qwen-finetune-deployment.json) 与 [训练对照报告](2026-10-04-qwen-finetune-report.md)。
