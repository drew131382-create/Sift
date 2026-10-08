import Foundation

struct ReprocessingReason: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case missingRequiredField, conflictingRequiredField, unreadableRequiredField, uncertainOwnership }
    var kind: Kind
    var field: FieldKind
    var detail: String
    var sceneID: UUID? = nil
    var id: String { "\(sceneID?.uuidString ?? "primary")/\(kind.rawValue)/\(field.rawValue)" }
}

enum CardCompleteness {
    static func requirements(_ category: Category) -> [[FieldKind]] {
        // A recognized scene is useful before every field is complete. Keep its
        // available title and OCR-backed fields on the home page; missing or
        // uncertain details remain editable in the card.
        return []
    }

    static func issues(category: Category, title: String, fields: [ExtractedField], previous: [ReprocessingReason], sceneID: UUID?) -> [ReprocessingReason] {
        var result: [ReprocessingReason] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.init(kind: .missingRequiredField, field: .topic, detail: "缺少具体主体", sceneID: sceneID))
        }
        return result
    }

    static func evaluate(_ item: InformationItem) -> [ReprocessingReason] {
        var fields = item.fields
        if !fields.contains(where: { $0.kind == .code }), !item.code.isEmpty { fields.append(.init(kind: .code, value: item.code, confidence: 1, sourceBlockIDs: [])) }
        if !fields.contains(where: { $0.kind == .amount }), !item.amount.isEmpty { fields.append(.init(kind: .amount, value: item.amount, confidence: 1, sourceBlockIDs: [])) }
        let previous = (item.reprocessingReasons ?? []).filter { $0.sceneID == nil } + (item.recognizedScenes?.first?.reprocessingReasons ?? [])
        var result = issues(category: item.category, title: item.title, fields: fields, previous: previous, sceneID: nil)
        for scene in (item.recognizedScenes ?? []).dropFirst() {
            result += issues(category: scene.category, title: scene.title, fields: scene.fields, previous: (scene.reprocessingReasons ?? []) + (item.reprocessingReasons ?? []).filter { $0.sceneID == scene.id }, sceneID: scene.id)
        }
        return result
    }

    private static func matches(_ expression: String, _ text: String) -> Bool {
        text.range(of: expression, options: .regularExpression) != nil
    }
}
