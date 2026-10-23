import Foundation
import UIKit
import UserNotifications

// MARK: - 本地备份（localStorage 的镜像文件，位于 Application Support，会随 iCloud 设备备份）
enum Store {
    private static var backupURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("ji-backup.json")
    }

    static func writeBackup(_ json: String) {
        guard json.utf8.count > 2, let data = json.data(using: .utf8) else { return }
        let url = backupURL
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: url, options: [.atomic])
        }
    }

    /// 备份文件内容（确认是合法的 JSON 对象才返回，避免破坏注入脚本）
    static func backupJSON() -> String? {
        guard let data = try? Data(contentsOf: backupURL),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any],
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}

// MARK: - 照片文件存储（Application Support/photos/<id>.jpg，通过 ji://app/photo/<id>.jpg 给网页显示）
enum Photos {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// id 只允许十六进制字符，防止路径穿越
    static func valid(_ id: String) -> Bool {
        id.count >= 6 && id.count <= 40 && id.allSatisfy { $0.isHexDigit }
    }

    static func fileURL(_ id: String) -> URL { dir.appendingPathComponent(id + ".jpg") }

    static func save(id: String, b64: String, done: @escaping (Bool) -> Void) {
        guard valid(id) else { done(false); return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = Data(base64Encoded: b64), !data.isEmpty else { done(false); return }
            done((try? data.write(to: fileURL(id), options: [.atomic])) != nil)
        }
    }

    /// 清理不再被任何记录引用的照片（10 分钟内新存的不动，避免误删）
    static func collectGarbage(keep: Set<String>) {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let cutoff = Date().addingTimeInterval(-600)
            for file in files where file.pathExtension == "jpg" {
                let id = file.deletingPathExtension().lastPathComponent
                if keep.contains(id) { continue }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                if modified < cutoff { try? fm.removeItem(at: file) }
            }
        }
    }
}

// MARK: - 触感
enum Haptics {
    static func fire(_ style: String) {
        switch style {
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "selection": UISelectionFeedbackGenerator().selectionChanged()
        default: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

// MARK: - 系统分享面板（导出票据图片 / 日历文件 / 备份）
enum Sharer {
    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    static func present(name: String?, b64: String?, text: String?, done: @escaping () -> Void) {
        var items: [Any] = []
        if let b64 = b64, let data = Data(base64Encoded: b64) {
            let safeName = (name ?? "file").replacingOccurrences(of: "/", with: "_")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
            try? FileManager.default.removeItem(at: url)
            if (try? data.write(to: url)) != nil { items.append(url) }
        }
        if items.isEmpty, let text = text, !text.isEmpty { items.append(text) }
        guard !items.isEmpty, let top = topController() else { done(); return }

        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
        sheet.completionWithItemsHandler = { _, _, _, _ in done() }
        top.present(sheet, animated: true)
    }
}

// MARK: - 本地通知（预约提醒，App 关闭后也会准时提醒）
enum Notifier {
    private static let prefix = "ji-rm-"

    static func status(_ done: @escaping (String) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: done("granted")
            case .denied: done("denied")
            default: done("default")
            }
        }
    }

    static func requestAuth(_ done: @escaping (String) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            done(granted ? "granted" : "denied")
        }
    }

    /// 用网页传来的预约列表整体替换已排期的提醒（系统上限 64 条，取最近的 60 条）
    static func sync(_ items: [[String: Any]]) {
        let center = UNUserNotificationCenter.current()
        let nowMs = Date().timeIntervalSince1970 * 1000
        let day = 86_400_000.0

        center.getPendingNotificationRequests { pending in
            let stale = pending.map { $0.identifier }.filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: stale)

            var planned: [(Double, UNNotificationRequest)] = []
            for item in items {
                guard let id = item["id"] as? String,
                      let title = item["title"] as? String,
                      let ts = (item["ts"] as? NSNumber)?.doubleValue else { continue }
                let kind = item["repeat"] as? String ?? "none"

                // 周期提醒：若第一次触发还很远，先按一次性提醒排期，免得提前响
                let period: Double = kind == "daily" ? day : (kind == "weekly" ? 7 * day : (kind == "monthly" ? 31 * day : 0))
                var repeats = kind != "none" && ts <= nowMs + period
                if !repeats && ts <= nowMs { continue }

                let date = Date(timeIntervalSince1970: ts / 1000)
                let cal = Calendar.current
                let comps: DateComponents
                if repeats && kind == "daily" {
                    comps = cal.dateComponents([.hour, .minute], from: date)
                } else if repeats && kind == "weekly" {
                    comps = cal.dateComponents([.weekday, .hour, .minute], from: date)
                } else if repeats && kind == "monthly" {
                    comps = cal.dateComponents([.day, .hour, .minute], from: date)
                } else {
                    repeats = false
                    comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                }

                let content = UNMutableNotificationContent()
                content.title = title
                content.body = item["body"] as? String ?? ""
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: repeats)
                planned.append((ts, UNNotificationRequest(identifier: prefix + id, content: content, trigger: trigger)))
            }

            planned.sort { $0.0 < $1.0 }
            for (_, request) in planned.prefix(60) {
                center.add(request, withCompletionHandler: nil)
            }
        }
    }
}
