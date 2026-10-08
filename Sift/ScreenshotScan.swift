import Foundation

struct ScreenshotDateRange: Hashable, Codable {
    var start: Date
    var end: Date

    static func recent(days: Int, now: Date = Date(), calendar: Calendar = .current) -> Self {
        let today = calendar.startOfDay(for: now)
        return Self(start: calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today)!, end: today)
    }

    func interval(now: Date = Date(), calendar: Calendar = .current) throws -> DateInterval {
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        guard first <= last else { throw ScanRangeError.reversed }
        guard last <= calendar.startOfDay(for: now) else { throw ScanRangeError.future }
        guard let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: last) else { throw ScanRangeError.reversed }
        return DateInterval(start: first, end: exclusiveEnd)
    }

    func contains(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let date, let interval = try? interval(now: now, calendar: calendar) else { return false }
        return date >= interval.start && date < interval.end
    }
}

enum AutomaticRecognitionSettings {
    static let enabledKey = "automaticScreenshotRecognition.enabled"
    static let retentionDaysKey = "automaticScreenshotRecognition.retentionDays"
    static let availableRetentionDays = [7, 30, 90]
    static let defaultRetentionDays = 7

    static func retentionDays(from defaults: UserDefaults) -> Int {
        let stored = defaults.integer(forKey: retentionDaysKey)
        return availableRetentionDays.contains(stored) ? stored : defaultRetentionDays
    }
}

enum ScanRangeError: LocalizedError {
    case reversed, future
    var errorDescription: String? {
        switch self {
        case .reversed: return "开始日期不能晚于结束日期。"
        case .future: return "请选择今天或之前的日期。"
        }
    }
}

struct ScanRecord: Codable {
    enum Outcome: String, Codable { case accepted, ignored }
    var assetIdentifier: String?
    var assetModifiedAt: Date?
    var assetCreatedAt: Date? = nil
    var fingerprint: String
    var ruleVersion: String
    var outcome: Outcome
    var key: String { assetIdentifier.map { "asset:\($0)" } ?? "hash:\(fingerprint)" }

    func matches(_ asset: LocalPhotoAsset, version: String = SemanticPolicy.version) -> Bool {
        assetIdentifier == asset.id && assetModifiedAt == asset.modifiedAt && ruleVersion == version
    }
}

struct ScanPreview {
    let total: Int
    let pending: Int
    let limitedAccess: Bool
}

enum ProcessingOutcome { case added, review, ignored, alreadyKnown, failed, interrupted }

struct ScanSession: Codable {
    var id = UUID()
    var range: ScreenshotDateRange
    var total: Int
    var report: ScanReport
    // System cancellation / memory pressure requires an explicit resume.
    var requiresResume = false
    var automatic: Bool? = nil
}

struct ScanReport: Codable {
    var added = 0
    // Codable key retained for legacy sessions; now counts incomplete cards.
    var review = 0
    var ignored = 0
    var alreadyKnown = 0
    var failed = 0
    var processed: Int { added + review + ignored + alreadyKnown + failed }
    mutating func include(_ outcome: ProcessingOutcome) {
        switch outcome {
        case .added: added += 1
        case .review: review += 1
        case .ignored: ignored += 1
        case .alreadyKnown: alreadyKnown += 1
        case .failed: failed += 1
        case .interrupted: break
        }
    }
    func summary(stopped: Bool = false) -> String {
        "\(stopped ? "扫描已停止" : "处理完成")\n新增 \(added) 张 · 需重新处理 \(review) 张\n无关跳过 \(ignored) 张 · 已处理跳过 \(alreadyKnown) 张\n失败 \(failed) 张"
    }
}
