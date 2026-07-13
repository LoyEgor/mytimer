import Foundation

let debugCommandNotification = Notification.Name("dev.egor.mytimer.debug-command")

func postDebugCommand(_ userInfo: [String: Any]) {
    DistributedNotificationCenter.default().postNotificationName(
        debugCommandNotification, object: nil, userInfo: userInfo, deliverImmediately: true)
    // Delivery is asynchronous; exiting immediately can drop the notification.
    usleep(200_000)
}

final class DebugLog {
    static let shared = DebugLog()
    let enabled = ProcessInfo.processInfo.environment["MYTIMER_DEBUG"] == "1"
    let path = NSTemporaryDirectory() + "mytimer-debug.log"

    func reset() {
        guard enabled else { return }
        FileManager.default.createFile(atPath: path, contents: Data())
    }

    func write(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(TimeFormat.iso8601.string(from: Date())) \(message())\n"
        guard let data = line.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
