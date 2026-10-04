import Foundation
import MLX
import Vision
import Darwin
import CryptoKit

@main struct EvaluationRunner {
    static let numericKinds = ["code", "amount", "price", "date", "time", "eventTime", "deadline", "documentReference"]
    struct ExpectedField: Codable {
        var kind: String
        var value: String
        var scene: Int?
        var unit: String?
        var currency: String?
    }
    struct Fixture: Codable {
        var id: String
        var origin: String
        var lines: [String]
        var accepted: Bool
        var category: String?
        var allowedCategories: [String]?
        var numeric: [String: String]
        var image: String?
        var reviewer: String?
        var reviewedAt: String?
        var expectedReview: Bool?
        var forbidden: [String: [String]]?
        var allowedNumeric: [String: [String]]?
        var sha256: String?
        var expectedFields: [ExpectedField]?
        var expectedFailure: Bool?
    }
    struct Result: Codable {
        var id: String
        var accepted: Bool
        var category: String?
        var state: String?
        var title: String?
        var note: String?
        var ocrSeconds: Double
        var ocrBlockCount: Int
        var fields: [String: String]
        var seconds: Double
        var decisionCorrect: Bool
        var numericCorrect: Int
        var numericTotal: Int
        var unexpectedNumeric: [String]
        var error: String?
        var errorKind: String?
        var forbiddenViolations: [String]
        var scenes: [RecognizedScene]?
        var extractedFields: [ExtractedField]?
        var reviewReasons: [String]?
        var metrics: ExtractionMetrics?
    }
    static func main() async throws {
        let arguments = CommandLine.arguments
        func option(_ name: String, fallback: String) -> String {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return fallback }
            return arguments[index + 1]
        }
        if arguments.contains("--inspect-model") {
            guard !arguments.contains("--real") else { throw SemanticError.invalidOutput }
            let profile = option("--model-profile", fallback: "bundled")
            guard ["bundled", "lfm2.5", "qwen0.6"].contains(profile) else { throw SemanticError.modelMissing }
            let identity: LocalModelIdentity = profile == "bundled" ? .bundled : (profile == "qwen0.6" ? .qwenBaseline : .lfmCandidate)
            let engine = LocalModelEngine(directory: URL(fileURLWithPath: option("--model", fallback: "Sift/Resources/LocalModel")), identity: identity)
            let results = try await engine.diagnose(prompts: ["请只回答：你好", "微信聊天：今天吃什么？火锅吧。判断这是取件通知、日程、消费、收藏还是无关。", "摄影教程：逆光人像需要曝光补偿。判断这是取件通知、日程、消费、收藏还是无关。"])
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: option("--output", fallback: "/tmp/SiftModelProbe.json")), options: .atomic)
            return
        }
        let fixturesURL = URL(fileURLWithPath: option("--fixtures", fallback: "Evaluation/synthetic_cases.json"))
        let outputURL = URL(fileURLWithPath: option("--output", fallback: "/tmp/SiftSemanticEvaluation.json"))
        var fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixturesURL))
        guard !fixtures.isEmpty else { throw SemanticError.invalidOutput }
        let replayPath = option("--replay-judgments",fallback:"")
        let replayOutputs = replayPath.isEmpty ? nil : try JSONDecoder().decode([String:[String]].self,from:Data(contentsOf:URL(fileURLWithPath:replayPath)))
        // Imported, actually measured classifier outputs. This is a development
        // grounding diagnostic, never a Qwen run or formal end-to-end acceptance.
        let classifierPath = option("--classifier-judgments",fallback:"")
        let classifierOutputs = classifierPath.isEmpty ? nil : try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:classifierPath))) as? [String:[String:String]]
        if !classifierPath.isEmpty && classifierOutputs == nil { throw SemanticError.invalidOutput }
        if classifierOutputs != nil && replayOutputs != nil { throw SemanticError.invalidOutput }
        let real = arguments.contains("--real")
        let useImages = real || arguments.contains("--images")
        let cachePath = option("--ocr-cache", fallback: "")
        let cachedDocuments = cachePath.isEmpty ? nil : try JSONDecoder().decode([String: OCRDocument].self, from: Data(contentsOf: URL(fileURLWithPath: cachePath)))
        if arguments.contains("--export-training-inputs") {
            guard !arguments.contains("--real"), let cachedDocuments else { throw SemanticError.invalidOutput }
            let exporter = LocalModelEngine(directory: URL(fileURLWithPath: option("--model", fallback: "Sift/Resources/LocalModel")))
            var exported: [String: [LocalModelEngine.TrainingInput]] = [:]
            for fixture in fixtures {
                guard let image = fixture.image, let expected = fixture.sha256, let document = cachedDocuments[fixture.id] else { throw SemanticError.invalidOutput }
                let hash = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: image))).map { String(format: "%02x", $0) }.joined()
                guard hash == expected else { throw SemanticError.invalidOutput }
                exported[fixture.id] = try await exporter.exportTrainingInputs(document: document)
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(exported).write(to: outputURL, options: .atomic)
            print("Exported actual offline production prompts for \(exported.count) verified screenshots; no model inference.")
            return
        }
        if replayOutputs != nil && cachedDocuments == nil { throw SemanticError.invalidOutput }
        if useImages && fixtures.contains(where: { ($0.image ?? "").isEmpty }) {
            throw NSError(domain: "SiftEvaluation", code: 3, userInfo: [NSLocalizedDescriptionKey: "Image evaluation requires an image path for every fixture; synthetic text fallback is disabled."])
        }
        if real {
            guard !arguments.contains("--model-only"), !arguments.contains("--diagnostic-raw"), replayOutputs == nil, classifierOutputs == nil, cachePath.isEmpty else { throw SemanticError.invalidOutput }
            guard fixtures.count >= 50,
                  fixtures.allSatisfy({ $0.origin == "human-annotated-screenshot" && !($0.image ?? "").isEmpty && !($0.reviewer ?? "").isEmpty && !($0.reviewedAt ?? "").isEmpty }) else {
                throw NSError(domain: "SiftEvaluation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Real acceptance requires at least 50 images with human reviewer and review date; generated fixtures are not eligible."])
            }
            guard Set(fixtures.map(\.id)).count == fixtures.count, fixtures.allSatisfy({ !($0.sha256 ?? "").isEmpty }), Set(fixtures.compactMap(\.sha256)).count == fixtures.count else { throw SemanticError.invalidOutput }
            guard fixtures.allSatisfy({ ($0.allowedNumeric ?? [:]).isEmpty }) else {
                throw NSError(domain: "SiftEvaluation", code: 4, userInfo: [NSLocalizedDescriptionKey: "Formal acceptance requires all expected numeric fields to be annotated; optional numeric allowances are diagnostic-only."])
            }
            guard fixtures.allSatisfy({ $0.expectedFields != nil }), fixtures.reduce(0,{ $0 + ($1.expectedFields ?? []).filter { numericKinds.contains($0.kind) }.count }) >= 50 else {
                throw NSError(domain:"SiftEvaluation",code:5,userInfo:[NSLocalizedDescriptionKey:"Formal acceptance requires a complete expectedFields list for every image and at least 50 critical numeric fields, including independent scenes."])
            }
            guard !arguments.contains("--limit") else { throw NSError(domain: "SiftEvaluation", code: 2, userInfo: [NSLocalizedDescriptionKey: "Real acceptance cannot use --limit."]) }
        }
        if let limit = Int(option("--limit", fallback: "0")), limit > 0 { fixtures = Array(fixtures.prefix(limit)) }
        let tracing: (@Sendable (String) -> Void)?
        if arguments.contains("--trace") { tracing = { value in print("MODEL " + value); fflush(stdout) } }
        else { tracing = nil }
        let modelDirectory = URL(fileURLWithPath: option("--model", fallback: "Sift/Resources/LocalModel"))
        let profile = option("--model-profile", fallback: "bundled")
        guard ["bundled", "lfm2.5", "qwen0.6", "qwen-finetuned"].contains(profile) else { throw SemanticError.modelMissing }
        let identity: LocalModelIdentity
        if profile == "qwen-finetuned" {
            // Candidate identity is never accepted as the pinned original revision.
            // This entry point exists only in the Mac developer evaluation executable.
            guard !real else { throw SemanticError.invalidOutput }
            let revision = option("--candidate-revision", fallback: "")
            guard revision.count == 64, revision.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw SemanticError.modelMissing }
            identity = LocalModelIdentity(modelID: "local/Sift-Qwen3-0.6B-QLoRA", revision: revision,
                versionPrefix: "sift-qwen3-0.6b-qlora", displayName: "Sift Qwen3 0.6B candidate", license: "Apache-2.0")
        } else {
            identity = profile == "bundled" ? .bundled : (profile == "qwen0.6" ? .qwenBaseline : .lfmCandidate)
        }
        let engine = LocalModelEngine(directory: modelDirectory, trace: tracing, modelOnly: arguments.contains("--model-only"), identity: identity)
        if arguments.contains("--judge-training-inputs") {
            guard !real, let cachedDocuments else { throw SemanticError.invalidOutput }
            var judged: [[String: Any]] = []
            for fixture in fixtures {
                guard let image = fixture.image, let expected = fixture.sha256, let document = cachedDocuments[fixture.id] else { throw SemanticError.invalidOutput }
                let hash = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: image))).map { String(format: "%02x", $0) }.joined()
                guard hash == expected else { throw SemanticError.invalidOutput }
                var outputs: [String] = [], failure: String? = nil
                do { outputs = try await engine.judgeScenesForTraining(document: document) }
                catch { failure = String(describing: error) }
                let metrics = await engine.lastMetrics
                judged.append(["id": fixture.id, "outputs": outputs, "error": failure as Any? ?? NSNull(),
                    "seconds": metrics.seconds, "modelCalls": metrics.modelCalls, "emptyOCR": document.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty])
                let report: [String: Any] = ["model": identity.modelID, "revision": identity.revision,
                    "results": judged, "complete": judged.count == fixtures.count,
                    "mode": "Actual production constrained decoder; scene judgment only; cached Vision OCR; no field/card admission", "mlxPeakBytes": await engine.peakModelMemory,
                    "independentAcceptance": false]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: outputURL, options: .atomic)
                print("\(judged.count)/\(fixtures.count) \(fixture.id) \(String(format: "%.2f", metrics.seconds))s outputs=\(outputs) error=\(failure ?? "none")")
                fflush(stdout)
            }
            await engine.release()
            return
        }
        var results: [Result] = []
        var documents: [String: OCRDocument] = [:]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func canonical(_ value: String) -> String { value.filter { !$0.isWhitespace } }
        for fixture in fixtures {
            let blocks = fixture.lines.enumerated().map { index, text in
                OCRBlock(text: text, boundingBox: CGRect(x: 0.05, y: index == 0 && text == "09:41" ? 0.96 : max(0.02, 0.88 - Double(index) * 0.07), width: 0.9, height: 0.03), confidence: 0.98)
            }
            let start = Date()
            var sceneDetails: [RecognizedScene]?, extractedFields: [ExtractedField]?, reviewReasons: [String]?
            var accepted = false, category: String?, state: String?, error: String?, errorKind: String?, title: String?, note: String?
            var ocrSeconds = 0.0, ocrBlockCount = 0
            var classifierMetrics: ExtractionMetrics?
            var fields: [String: String] = [:]
            do {
                var document: OCRDocument
                if let cachedDocuments {
                    guard let cached = cachedDocuments[fixture.id], let image = fixture.image, let expected = fixture.sha256 else { throw SemanticError.invalidOutput }
                    let hash = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: image))).map { String(format: "%02x", $0) }.joined()
                    guard hash == expected else { throw SemanticError.invalidOutput }
                    document = cached
                } else if useImages, let image = fixture.image {
                    let url = image.hasPrefix("/") ? URL(fileURLWithPath: image) : fixturesURL.deletingLastPathComponent().appendingPathComponent(image)
                    if real {
                        let hash = SHA256.hash(data:try Data(contentsOf:url)).map { String(format:"%02x",$0) }.joined()
                        guard hash == fixture.sha256 else { throw SemanticError.invalidOutput }
                    }
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = true
                    try VNImageRequestHandler(url: url).perform([request])
                    let detected = (request.results ?? []).compactMap { observation -> OCRBlock? in
                        guard let text = observation.topCandidates(1).first else { return nil }
                        return OCRBlock(text: text.string, boundingBox: observation.boundingBox, confidence: Double(text.confidence))
                    }
                    document = OCRDocument(rawText: detected.map(\.text).joined(separator: "\n"), blocks: detected, recognitionLanguage: "zh-Hans,en-US", engineVersion: "Vision-accurate-macOS")
                } else {
                    document = OCRDocument(rawText: fixture.lines.joined(separator: "\n"), blocks: blocks, recognitionLanguage: "zh-Hans", engineVersion: "synthetic-text-fixture")
                }
                ocrSeconds = Date().timeIntervalSince(start); ocrBlockCount = document.blocks.count
                if useImages {
                    documents[fixture.id] = document.textOnly
                    try encoder.encode(documents).write(to: outputURL.deletingPathExtension().appendingPathExtension("ocr.json"), options: .atomic)
                }
                let decision: ExtractionDecision
                if let classifierOutputs {
                    let started = Date()
                    classifierMetrics = ExtractionMetrics(path:"classifierGroundingReplay")
                    guard let output = classifierOutputs[fixture.id] else { throw SemanticError.invalidOutput }
                    let layout = LayoutAnalysis(document:document)
                    if document.rawText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                        guard output["category"] == "无关", output["arrangement"] == "无" else { throw SemanticError.invalidOutput }
                        decision = .ignored
                    } else if !arguments.contains("--model-only"), let direct = try GroundedExtraction.direct(layout) {
                        decision = direct
                    } else {
                        let raw = String(decoding:try JSONSerialization.data(withJSONObject:output),as:UTF8.self)
                        let selection = try SceneJudgmentPolicy.decode(raw,layout:layout)
                        let modelDecision = try SceneJudgmentPolicy.validate(selection,layout:layout)
                        let partial = arguments.contains("--model-only") ? nil : try GroundedExtraction.direct(layout,requireComplete:false)
                        decision = GroundedExtraction.merge([partial,modelDecision].compactMap { $0 })
                    }
                    classifierMetrics?.seconds = Date().timeIntervalSince(started)
                }
                else if let replayOutputs { decision = try await engine.replay(document:document,outputs:replayOutputs[fixture.id] ?? []) }
                else { decision = try await engine.evaluate(document:document) }
                if case .accepted(let item) = decision {
                    accepted = true; category = item.category.rawValue; state = item.state.rawValue; title = item.title; note = item.note
                    sceneDetails = item.recognizedScenes; extractedFields = item.fields; reviewReasons = item.reviewReasons
                    for field in item.fields { if fields[field.kind.rawValue] == nil { fields[field.kind.rawValue] = field.value } }
                }
            } catch let failure { error = failure.localizedDescription; errorKind = (failure as? SemanticError).map { String(describing:$0) } }
            var exact = fixture.numeric.filter { entry in fields[entry.key].map { canonical($0) == canonical(entry.value) } == true }.count
            var unexpected = fields.filter { entry in
                numericKinds.contains(entry.key) && fixture.numeric[entry.key] == nil
                    && !(fixture.allowedNumeric?[entry.key]?.contains { canonical($0) == canonical(entry.value) } ?? false)
            }.map { "\($0.key)=\($0.value)" }
            let actualScenes = sceneDetails?.map(\.fields) ?? [extractedFields ?? []]
            let allActual = actualScenes.enumerated().flatMap { scene, values in values.map { (scene,$0) } }
            var total = fixture.numeric.count
            if let expectations = fixture.expectedFields {
                let expected = expectations.filter { numericKinds.contains($0.kind) }
                var unused = allActual.filter { numericKinds.contains($0.1.kind.rawValue) }
                exact = 0; total = expected.count
                for field in expected {
                    if let index = unused.firstIndex(where:{ actual in
                        actual.1.kind.rawValue == field.kind && canonical(actual.1.value) == canonical(field.value)
                            && (field.scene == nil || field.scene == actual.0)
                            && (field.unit == nil || field.unit == actual.1.unit)
                            && (field.currency == nil || field.currency == actual.1.currency)
                    }) { exact += 1; unused.remove(at:index) }
                }
                unexpected = unused.map { "scene\($0.0):\($0.1.kind.rawValue)=\($0.1.value)" }
            }
            let forbidden = allActual.filter { actual in fixture.forbidden?[actual.1.kind.rawValue]?.contains { canonical($0) == canonical(actual.1.value) } == true }.map { "\($0.1.kind.rawValue)=\($0.1.value)" }
            let categoryCorrect = !accepted || ((fixture.category == nil || category == fixture.category)
                && (fixture.allowedCategories == nil || fixture.allowedCategories!.contains(category ?? "")))
            let correct = (fixture.expectedFailure == true ? errorKind == "invalidOutput" : error == nil) && accepted == fixture.accepted && categoryCorrect && (fixture.expectedReview == nil || fixture.expectedReview == (state == "needsReview"))
            let engineMetrics = await engine.lastMetrics
            let result = Result(id: fixture.id, accepted: accepted, category: category, state: state, title: title, note: note, ocrSeconds: ocrSeconds, ocrBlockCount: ocrBlockCount, fields: fields, seconds: Date().timeIntervalSince(start), decisionCorrect: correct, numericCorrect: exact, numericTotal: total, unexpectedNumeric: unexpected, error: error, errorKind: errorKind, forbiddenViolations: forbidden, scenes: sceneDetails, extractedFields: extractedFields, reviewReasons: reviewReasons, metrics: classifierMetrics ?? engineMetrics)
            results.append(result)
            try encoder.encode(results).write(to: outputURL, options: .atomic)
            print("\(results.count)/\(fixtures.count) \(fixture.id): decision=\(correct) numeric=\(exact)/\(fixture.numeric.count) time=\(String(format: "%.1f", result.seconds))s error=\(error ?? "none")")
            fflush(stdout)
        }
        let correct = results.filter(\.decisionCorrect).count
        let numericTotal = results.reduce(0) { $0 + $1.numericTotal }
        let numericCorrect = results.reduce(0) { $0 + $1.numericCorrect }
        let extra = results.reduce(0) { $0 + $1.unexpectedNumeric.count }
        let violations = results.reduce(0) { $0 + $1.forbiddenViolations.count }
        let decisionAccuracy = Double(correct) / Double(max(1, results.count))
        let numericAccuracy = Double(numericCorrect) / Double(max(1, numericTotal + extra))
        let passed = real && decisionAccuracy >= 0.90 && numericAccuracy >= 0.98 && violations == 0 && results.allSatisfy { result in result.error == nil || result.errorKind == "invalidOutput" && fixtures.first(where: { $0.id == result.id })?.expectedFailure == true }
        func pathSummary(_ path: String) -> [String:Any] {
            let times = results.filter { $0.metrics?.path == path }.compactMap { $0.metrics?.seconds }.sorted()
            func percentile(_ p:Double) -> Double { times.isEmpty ? 0 : times[min(times.count-1,Int(ceil(Double(times.count)*p))-1)] }
            return ["count":times.count,"medianSeconds":times.isEmpty ? 0 : (times[(times.count-1)/2]+times[times.count/2])/2,"p95Seconds":percentile(0.95)]
        }
        let summary: [String: Any] = ["modelID": classifierOutputs == nil ? identity.modelID : "hfl/rbt3-supervised-coreml-candidate", "modelRevision": classifierOutputs == nil ? identity.revision : "see classifier deployment-manifest.json", "modelTask": "scene-and-arrangement-only", "modelImageInput": false, "replayedSemanticJudgments": replayOutputs != nil, "importedClassifierJudgments":classifierOutputs != nil,"classifierInferenceMeasuredHere":false, "realScreenshotAcceptance": real, "actualScreenshotInputs": useImages, "imageReadForOCRThisRun":useImages && cachedDocuments == nil,"cachedVisionOCR": cachedDocuments != nil, "annotationOrigins": Array(Set(fixtures.map(\.origin))).sorted(), "passed": passed, "policy": identity.policyVersion, "samples": results.count,
            "decisionCorrect": correct, "decisionAccuracy": decisionAccuracy, "numericCorrect": numericCorrect, "numericExpected": numericTotal, "unexpectedNumeric": extra,
            "numericAccuracyIncludingUnexpected": numericAccuracy, "forbiddenViolations": violations, "mlxPeakBytes": Memory.peakMemory,
            "paths": ["direct":pathSummary("direct"),"model":pathSummary("model"),"hybrid":pathSummary("hybrid"),"validationReplay":pathSummary("validationReplay")], "modelCalls": results.reduce(0) { $0 + ($1.metrics?.modelCalls ?? 0) }, "fullImageMedianSeconds": (results.map(\.seconds).sorted()[(results.count-1)/2]+results.map(\.seconds).sorted()[results.count/2])/2,
            "platform": "macOS; iPhone timing and memory require device validation"]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: outputURL.deletingPathExtension().appendingPathExtension("summary.json"), options: .atomic)
        let provenance = real ? "REAL SCREENSHOTS" : classifierOutputs != nil ? "CLASSIFIER + GROUNDING DIAGNOSTIC" : cachedDocuments != nil ? "CACHED VISION OCR DIAGNOSTIC" : useImages ? "REAL IMAGE DIAGNOSTIC; NOT HUMAN ACCEPTANCE" : "SYNTHETIC ONLY"
        print("\(provenance): decisions \(correct)/\(results.count), exact numeric \(numericCorrect)/\(numericTotal), unexpected numeric \(extra), forbidden \(violations), MLX peak memory \(Memory.peakMemory) bytes. Acceptance passed=\(passed).")
        await engine.release()
        if real && !passed { exit(2) }
    }
}
