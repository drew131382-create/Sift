import BackgroundTasks
import UIKit

/// A foreground user action creates this grant. An ordinary UIKit background
/// lease must never be used to run MLX's Metal inference in the background.
@MainActor
final class BackgroundScan {
    private var identifier: String?
    private var current: BGTask?
    private var completed = 0
    private var total = 1
    var isGranted: Bool { current != nil }

    func begin(total: Int, onExpiration: @escaping @MainActor () -> Void) async -> String? {
        // A foreground-only build uses the existing device profile without claiming
        // the GPU entitlement. The standard build keeps the background capability.
        if Bundle.main.object(forInfoDictionaryKey: "SiftBackgroundGPUEnabled") as? String == "false" {
            return "当前安装版本未获后台 GPU 签名授权，离开应用时会保存进度。"
        }
        guard #available(iOS 26.0, *) else { return "当前系统不支持后台本地理解，离开应用时会保存进度。" }
        guard BGTaskScheduler.supportedResources.contains(.gpu) else {
            return "当前设备未开放后台 GPU，离开应用时会保存进度。"
        }
        end(success: false)
        self.total = max(1, total)
        completed = 0
        let id = "\(Bundle.main.bundleIdentifier ?? "com.sift.local").scan.\(UUID().uuidString)"
        identifier = id
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, self.identifier == id, let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false); return
                }
                self.current = task
                task.expirationHandler = {
                    // Stop token generation immediately; checkpoint on the main actor.
                    LocalModelEngine.shared.interrupt()
                    Task { @MainActor in onExpiration() }
                }
                self.update(completed: self.completed, total: self.total, stage: 0, subtitle: "正在扫描截图")
            }
        }
        guard registered else { identifier = nil; return "后台扫描注册失败，离开应用时会保存进度。" }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: "Sift · 扫描截图", subtitle: "准备本地识别")
        request.requiredResources = .gpu
        request.strategy = .fail
        do {
            if #available(iOS 27.0, *) {
                try await Task.detached(priority: .userInitiated) {
                    try await BGTaskScheduler.shared.submitTaskRequest(request)
                }.value
            } else {
                try BGTaskScheduler.shared.submit(request)
            }
            return nil
        } catch {
            end(success: false)
            return "系统暂未允许后台扫描，离开应用时会保存进度。"
        }
    }

    func update(completed: Int, total: Int, stage: Int = 0, subtitle: String) {
        self.completed = completed
        self.total = max(1, total)
        guard #available(iOS 26.0, *), let task = current as? BGContinuedProcessingTask else { return }
        task.progress.totalUnitCount = Int64(self.total * 4)
        task.progress.completedUnitCount = Int64(min(self.total * 4, completed * 4 + stage))
        task.updateTitle("Sift · 扫描截图", subtitle: "\(completed) / \(total) 张 · \(subtitle)")
    }

    func end(success: Bool) {
        current?.expirationHandler = nil
        current?.setTaskCompleted(success: success)
        current = nil
        if let identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        identifier = nil
    }
}
