import Foundation
import CryptoKit
import MLX
import MLXLLM
import MLXLMCommon
import MLXGuidedGeneration
import Tokenizers

/// No remote model identifier, downloader or Hub API is used by this loader.
private struct OfflineTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        OfflineTokenizer(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

private struct OfflineTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}

private final class InferenceControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    func reset() { lock.lock(); stopped = false; lock.unlock() }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

private final class GenerationBias: @unchecked Sendable {
    let closing: MLXArray
    let whitespace: MLXArray
    let whitespaceIDs: Set<Int>
    init(tokenizer: any MLXLMCommon.Tokenizer) {
        closing = ClosingTokenBias.compute(tokenizer: tokenizer, eosTokenId: tokenizer.eosTokenId)
        let bias = WhitespaceTokenBias.compute(tokenizer: tokenizer)
        whitespace = bias.bias
        whitespaceIDs = bias.tokenIDs
        eval(closing, whitespace)
    }
}

enum SemanticInput {
    struct Segment: Codable {
        var id: Int
        var text: String
        var box: [Double]
        var confidence: Double
    }

    /// Break even a single oversized OCR block into overlapping segments; never drop its tail.
    static func chunks(_ blocks: [OCRBlock], characterBudget: Int = 2400) -> [[Segment]] {
        var chunks: [[Segment]] = [], current: [Segment] = [], count = 0
        for (id, block) in blocks.enumerated() {
            if SemanticValidator.isStatus(block) { continue }
            let characters = Array(block.text)
            var start = 0
            repeat {
                let end = min(characters.count, start + max(100, characterBudget / 2))
                let text = String(characters[start..<end])
                if count + text.count > characterBudget && !current.isEmpty {
                    chunks.append(current); current = []; count = 0
                }
                current.append(Segment(id: id, text: text, box: [Double(block.boundingBox.minX), Double(block.boundingBox.minY), Double(block.boundingBox.width), Double(block.boundingBox.height)], confidence: block.confidence))
                count += text.count
                if end >= characters.count { break }
                start = end - min(80, (end - start) / 4)
            } while start < characters.count
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    static func merge(_ responses: [SemanticResponse]) -> SemanticResponse {
        var result: [SemanticScene] = []
        for scene in responses.flatMap(\.scenes) {
            // Separate schedules keep their own proof: merging by category could
            // turn a cancelled booking and an unrelated date into one valid event.
            if scene.category != Category.event.rawValue, let index = result.firstIndex(where: { $0.category == scene.category }) {
                result[index].needsReview = result[index].needsReview || scene.needsReview || result[index].title != scene.title
                result[index].fields += scene.fields
                result[index].evidence = Array(Set(result[index].evidence + scene.evidence)).sorted().prefix(8).map { $0 }
            } else { result.append(scene) }
        }
        return SemanticResponse(scenes: result)
    }
}

struct ExtractionMetrics: Codable {
    var path = "layout"
    var seconds = 0.0
    var modelCold = false
    var modelCalls = 0
    var inputTokens: [Int] = []
    var outputTokens: [Int] = []
}

actor LocalModelEngine: SemanticExtracting {
    static let shared = LocalModelEngine()
    private let directory: URL?
    private let identity: LocalModelIdentity
    private let trace: (@Sendable (String) -> Void)?
    private var container: ModelContainer?
    private var grammarTokenizer: GrammarTokenizer?
    private var generationBias: GenerationBias?
    private var running = false
    private var idleRelease: Task<Void, Never>?
    #if os(macOS)
    private var replayTokenizer: (any MLXLMCommon.Tokenizer)?
    #endif
    private let modelOnly: Bool
    private(set) var lastMetrics = ExtractionMetrics()
    private let control = InferenceControl()

    init(directory: URL? = Bundle.main.url(forResource: "LocalModel", withExtension: nil), trace: (@Sendable (String) -> Void)? = nil, modelOnly: Bool = false, identity: LocalModelIdentity = .bundled) {
        self.directory = directory
        self.identity = identity
        self.trace = trace
        self.modelOnly = modelOnly
    }

    nonisolated func interrupt() { control.stop() }
    var peakModelMemory: Int {
        #if targetEnvironment(simulator)
        return 0
        #else
        return Memory.peakMemory
        #endif
    }

    func release() {
        idleRelease?.cancel(); idleRelease = nil
        control.stop()
        container = nil
        grammarTokenizer = nil
        generationBias = nil
        #if !targetEnvironment(simulator)
        Memory.clearCache()
        #endif
    }

    func evaluate(document: OCRDocument) async throws -> ExtractionDecision {
        guard !running else { throw SemanticError.interrupted }
        idleRelease?.cancel(); idleRelease = nil
        running = true
        control.reset()
        let started = Date()
        lastMetrics = ExtractionMetrics()
        defer {
            lastMetrics.seconds = Date().timeIntervalSince(started)
            running = false
            if control.isStopped { release() }
            else {
                idleRelease = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                    await self?.releaseIfIdle()
                }
            }
        }
        let layout = LayoutAnalysis(document: document)
        guard !document.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastMetrics.path = "ignoredEmptyOCR"
            return .ignored
        }
        guard layout.blocks.indices.contains(where: { layout.regions[$0] >= 0 && !LayoutAnalysis.noise(layout.blocks[$0]) }) else {
            lastMetrics.path = "ignoredInterfaceOnly"
            return .ignored
        }
        if !modelOnly, let decision = try GroundedExtraction.direct(layout) {
            lastMetrics.path = "direct"
            trace?("PATH direct seconds=\(Date().timeIntervalSince(started))")
            return applyingModelVersion(decision)
        }
        let partial = modelOnly ? nil : try GroundedExtraction.direct(layout,requireComplete:false)
        lastMetrics.path = partial == nil ? "model" : "hybrid"
        #if targetEnvironment(simulator)
        throw SemanticError.unsupportedDevice
        #else
        // The deadline covers load, all chunks and generation, rather than each call.
        let deadline = Date().addingTimeInterval(30)
        guard let directory else { throw SemanticError.modelMissing }
        if container == nil {
            lastMetrics.modelCold = true
            try Self.verifyBundle(directory, identity: identity)
            guard !control.isStopped, !Task.isCancelled else { throw SemanticError.interrupted }
            Memory.cacheLimit = 32 * 1024 * 1024
            container = try await LLMModelFactory.shared.loadContainer(from: directory, using: OfflineTokenizerLoader())
        }
        guard !control.isStopped, !Task.isCancelled else { throw SemanticError.interrupted }
        guard Date() < deadline else { throw SemanticError.timeout }
        guard let model = container else { throw SemanticError.modelMissing }
        if grammarTokenizer == nil {
            grammarTokenizer = try await model.perform { context in
                let vocab = TokenizerVocabExtractor.extractForGrammar(from: context.tokenizer)
                return try GrammarTokenizer(vocab: vocab.vocab, vocabType: vocab.vocabType, eosTokenId: Int32(context.tokenizer.eosTokenId ?? 0))
            }
        }
        if generationBias == nil { generationBias = await model.perform { GenerationBias(tokenizer: $0.tokenizer) } }
        guard let grammarTokenizer, let bias = generationBias else { throw SemanticError.modelMissing }
        let tokenizer = await model.tokenizer
        let payloads = try SceneJudgmentInput.chunks(layout, tokenizer: tokenizer)
        guard !payloads.isEmpty else { throw SemanticError.invalidOutput }
        trace?("PATH model chunks=\(payloads.count)")
        var scenes: [SemanticSelection.Scene] = []
        for payload in payloads {
            guard !control.isStopped, !Task.isCancelled else { throw SemanticError.interrupted }
            guard Date() < deadline else { throw SemanticError.timeout }
            lastMetrics.modelCalls += 1
            lastMetrics.inputTokens.append(try SceneJudgmentInput.count(payload,tokenizer:tokenizer))
            let output = try await generate(model: model, grammarTokenizer: grammarTokenizer, bias: bias,
                payload: payload, instructions: SceneJudgmentPolicy.instructions, schema: SceneJudgmentPolicy.schema, maxTokens: 192, deadline: deadline)
            lastMetrics.outputTokens.append(tokenizer.encode(text:output).count)
            trace?("SCENE JUDGMENT " + output)
            let response: SemanticSelection
            do { response = try SceneJudgmentPolicy.decode(output, layout: layout, payload:payload) }
            catch SemanticError.invalidOutput { throw SemanticError.unverifiedFields }
            // Validate every segment before merging. Malformed IDs never become ignored records.
            do { _ = try SceneJudgmentPolicy.validate(response, layout: layout, checkIgnoreProof:false) }
            catch SemanticError.invalidOutput { throw SemanticError.unverifiedFields }
            scenes += response.s
        }
        let modelDecision: ExtractionDecision
        do { modelDecision = try SceneJudgmentPolicy.validate(SemanticSelection(s: scenes, u: scenes.isEmpty ? "ignore" : "content"), layout: layout) }
        catch SemanticError.invalidOutput { throw SemanticError.unverifiedFields }
        let decision = GroundedExtraction.merge([partial,modelDecision].compactMap { $0 })
        trace?("MODEL seconds=\(Date().timeIntervalSince(started))")
        return applyingModelVersion(decision)
        #endif
    }

    private func releaseIfIdle() { if !running { release() } }

    private func applyingModelVersion(_ decision: ExtractionDecision) -> ExtractionDecision {
        guard case .accepted(var item) = decision else { return decision }
        item.classificationVersion = identity.policyVersion
        return .accepted(DisplayAdmission.apply(to: item))
    }

    #if os(macOS)
    struct TrainingInput: Codable {
        var system: String
        var payload: String
        var prompt: String
        var promptTokens: [Int]
        var schema: String
    }

    /// Export the actual production template and token-limited OCR chunks, without
    /// loading weights. No labels, filenames or reviewer notes enter model input.
    func exportTrainingInputs(document: OCRDocument) async throws -> [TrainingInput] {
        guard let directory else { throw SemanticError.modelMissing }
        guard !document.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let tokenizer = try await OfflineTokenizerLoader().load(from: directory)
        return try SceneJudgmentInput.chunks(LayoutAnalysis(document: document), tokenizer: tokenizer).map { payload in
            let tokens = try tokenizer.applyChatTemplate(messages: [
                ["role": "system", "content": SceneJudgmentPolicy.instructions],
                ["role": "user", "content": payload]
            ], tools: nil, additionalContext: ["enable_thinking": false])
            return TrainingInput(system: SceneJudgmentPolicy.instructions, payload: payload,
                prompt: tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false),
                promptTokens: tokens, schema: SceneJudgmentPolicy.schema)
        }
    }

    /// Compare scene judgments independently of downstream field admission, using
    /// the exact production constrained decoder, token budget and KV precision.
    /// This is not a card-admission API and is unavailable in the iPhone app.
    func judgeScenesForTraining(document: OCRDocument) async throws -> [String] {
        lastMetrics = ExtractionMetrics(path: "modelClassificationDiagnostic")
        let started = Date()
        defer { lastMetrics.seconds = Date().timeIntervalSince(started) }
        guard !document.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard let directory else { throw SemanticError.modelMissing }
        control.reset()
        if container == nil {
            try Self.verifyBundle(directory, identity: identity)
            container = try await LLMModelFactory.shared.loadContainer(from: directory, using: OfflineTokenizerLoader())
            lastMetrics.modelCold = true
        }
        guard let model = container else { throw SemanticError.modelMissing }
        if grammarTokenizer == nil {
            grammarTokenizer = try await model.perform { context in
                let vocab = TokenizerVocabExtractor.extractForGrammar(from: context.tokenizer)
                return try GrammarTokenizer(vocab: vocab.vocab, vocabType: vocab.vocabType,
                    eosTokenId: Int32(context.tokenizer.eosTokenId ?? 0))
            }
        }
        if generationBias == nil { generationBias = await model.perform { GenerationBias(tokenizer: $0.tokenizer) } }
        guard let grammarTokenizer, let bias = generationBias else { throw SemanticError.modelMissing }
        let tokenizer = await model.tokenizer
        let payloads = try SceneJudgmentInput.chunks(LayoutAnalysis(document: document), tokenizer: tokenizer)
        guard !payloads.isEmpty else { throw SemanticError.invalidOutput }
        let deadline = started.addingTimeInterval(30)
        var outputs: [String] = []
        for payload in payloads {
            lastMetrics.modelCalls += 1
            lastMetrics.inputTokens.append(try SceneJudgmentInput.count(payload, tokenizer: tokenizer))
            let output = try await generate(model: model, grammarTokenizer: grammarTokenizer, bias: bias,
                payload: payload, instructions: SceneJudgmentPolicy.instructions,
                schema: SceneJudgmentPolicy.schema, maxTokens: 192, deadline: deadline)
            lastMetrics.outputTokens.append(tokenizer.encode(text: output).count)
            outputs.append(output)
        }
        return outputs
    }

    /// Developer compatibility probe, never used for admission or acceptance.
    func diagnose(prompts: [String]) async throws -> [[String: String]] {
        guard let directory else { throw SemanticError.modelMissing }
        try Self.verifyBundle(directory, identity: identity)
        let probe = try await LLMModelFactory.shared.loadContainer(from: directory, using: OfflineTokenizerLoader())
        var results: [[String: String]] = []
        for prompt in prompts {
            let result = try await probe.perform { context in
                let input = try await context.processor.prepare(input: UserInput(chat: [.system("请根据用户要求回答。"), .user(prompt)]))
                let logits = context.model(input.text[text: .newAxis], cache: nil, state: nil).logits[0, -1, 0...].asType(.float32)
                eval(logits)
                let values = logits.asArray(Float.self)
                let top = values.indices.sorted { values[$0] > values[$1] }.prefix(5)
                let generated = try MLXLMCommon.generate(input: input, parameters: GenerateParameters(maxTokens: 96, temperature: 0), context: context) { (_: [Int]) in GenerateDisposition.more }
                return ["prompt": prompt, "decodedInput": context.tokenizer.decode(tokenIds: input.text.tokens.asArray(Int.self)),
                        "inputTokens": String(input.text.tokens.size), "nonFiniteLogits": String(values.filter { !$0.isFinite }.count),
                        "topTokens": top.map { "\($0):\(context.tokenizer.decode(tokenIds: [$0])):\(values[$0])" }.joined(separator: " | "),
                        "output": generated.output]
            }
            results.append(result)
        }
        return results
    }

    /// Developer-only deterministic validation replay. No generation and no acceptance timing.
    func replay(document: OCRDocument, outputs: [String]) async throws -> ExtractionDecision {
        let started = Date()
        lastMetrics = ExtractionMetrics(path:"validationReplay")
        defer { lastMetrics.seconds = Date().timeIntervalSince(started) }
        let layout = LayoutAnalysis(document:document)
        guard !document.rawText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw SemanticError.invalidOutput }
        if !modelOnly, let direct = try GroundedExtraction.direct(layout) { return applyingModelVersion(direct) }
        guard let directory else { throw SemanticError.modelMissing }
        if replayTokenizer == nil { replayTokenizer = try await OfflineTokenizerLoader().load(from:directory) }
        guard let tokenizer = replayTokenizer else { throw SemanticError.modelMissing }
        let payloads = try SceneJudgmentInput.chunks(layout,tokenizer:tokenizer)
        guard !payloads.isEmpty, outputs.count == payloads.count else { throw SemanticError.invalidOutput }
        var scenes: [SemanticSelection.Scene] = []
        for (payload,output) in zip(payloads,outputs) {
            lastMetrics.inputTokens.append(try SceneJudgmentInput.count(payload,tokenizer:tokenizer))
            let selection = try SceneJudgmentPolicy.decode(output,layout:layout,payload:payload)
            _ = try SceneJudgmentPolicy.validate(selection,layout:layout,checkIgnoreProof:false)
            scenes += selection.s
        }
        let modelDecision = try SceneJudgmentPolicy.validate(.init(s:scenes,u:scenes.isEmpty ? "ignore" : "content"),layout:layout)
        let partial = modelOnly ? nil : try GroundedExtraction.direct(layout,requireComplete:false)
        return applyingModelVersion(GroundedExtraction.merge([partial,modelDecision].compactMap { $0 }))
    }
    #endif

    private func generate(model: ModelContainer, grammarTokenizer: GrammarTokenizer, bias: GenerationBias,
                          payload: String, instructions: String, schema: String, maxTokens: Int, deadline: Date) async throws -> String {
        let control = self.control
        let trace = self.trace
        do {
            return try await model.perform { context in
                let grammarStart = Date()
                let constraint = try GrammarConstraint(tokenizer: grammarTokenizer, jsonSchema: schema, fastForward: true, hostTokenizer: context.tokenizer)
                trace?("grammar seconds=\(Date().timeIntervalSince(grammarStart))")
                let input = try await context.processor.prepare(input: UserInput(chat: [.system(instructions), .user(payload)], additionalContext: ["enable_thinking": false]))
                guard Date() < deadline else { throw SemanticError.timeout }
                guard input.text.tokens.size <= 2048 else { throw SemanticError.invalidOutput }
                trace?("INPUT tokens=\(input.text.tokens.size) suffix=" + context.tokenizer.decode(tokenIds: Array(input.text.tokens.asArray(Int.self).suffix(20))))
                var output = ""
                try GuidedGenerationLoop.run(input: input, context: context, constraint: constraint, maxTokens: maxTokens, vocabSize: grammarTokenizer.vocabSize, kvBits: 8, completionReserve: min(192, maxTokens / 4), hardReserve: min(64, maxTokens / 12), closingBias: bias.closing, whitespaceBias: bias.whitespace, whitespaceTokenIDs: bias.whitespaceIDs) { delta in
                    output += delta
                    return !control.isStopped && !Task.isCancelled && Date() < deadline
                }
                guard !control.isStopped, !Task.isCancelled else { throw SemanticError.interrupted }
                guard Date() < deadline else { throw SemanticError.timeout }
                return output
            }
        } catch let error as SemanticError { throw error }
        catch {
            if control.isStopped || Task.isCancelled { throw SemanticError.interrupted }
            if Date() >= deadline { throw SemanticError.timeout }
            trace?("GENERATION ERROR " + String(describing: error))
            throw SemanticError.inferenceFailed
        }
    }

    private static func payload(_ segments: [SemanticInput.Segment]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(segments)
        return "以下是截图OCR数据，id用于evidence、scheduleEvidence.sources和字段valueSources；box是位置，原点在左下角。识别业务信息并返回JSON。\n" + String(decoding: data, as: UTF8.self)
    }

    private static func tokens(_ segments: [SemanticInput.Segment], tokenizer: any MLXLMCommon.Tokenizer) throws -> [Int] {
        try tokenizer.applyChatTemplate(messages: [["role": "system", "content": SemanticPolicy.instructions], ["role": "user", "content": payload(segments)]], tools: nil, additionalContext: ["enable_thinking": false])
    }

    private struct Manifest: Decodable {
        struct File: Decodable { var name: String; var bytes: Int; var sha256: String }
        var model: String
        var revision: String
        var files: [File]
    }

    static func verifyBundle(_ directory: URL, identity: LocalModelIdentity = .bundled) throws {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.model == identity.modelID,
              manifest.revision == identity.revision,
              Set(manifest.files.map(\.name)).count == manifest.files.count,
              Set(manifest.files.map(\.name)).isSuperset(of: ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"]) else { throw SemanticError.modelMissing }
        for file in manifest.files {
            guard ![".", ".."].contains(file.name), !file.name.contains("/"), !file.name.contains("\\"), let stream = try? FileHandle(forReadingFrom: directory.appendingPathComponent(file.name)) else { throw SemanticError.modelMissing }
            defer { try? stream.close() }
            var digest = SHA256(), count = 0
            while let chunk = try stream.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { digest.update(data: chunk); count += chunk.count }
            guard count == file.bytes, digest.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw SemanticError.modelMissing }
        }
    }
}
