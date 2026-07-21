import Foundation

enum TimeFormat {
    static let iso8601 = ISO8601DateFormatter()

    private static let hourMinute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func fireTime(_ date: Date) -> String {
        hourMinute.string(from: date)
    }

    static func compactRemaining(until date: Date, now: Date = Date()) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        // Clamp to 1...59 so rounding never yields "0s" or "60s".
        if seconds < 60 { return "\(min(59, max(1, Int(seconds.rounded()))))s" }
        let minutes = Int(ceil(seconds / 60))
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h\(String(format: "%02d", minutes % 60))m"
    }

    static func spokenDuration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        // Always include minutes so the drag bubble width stays stable.
        return "\(minutes / 60) hr \(minutes % 60) min"
    }

    static func remainingDescription(until date: Date, now: Date = Date()) -> String {
        spokenDuration(minutes: max(1, Int(ceil(date.timeIntervalSince(now) / 60))))
    }

    static func parseManualEntry(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let minutes = Double(value), minutes > 0 { return now.addingTimeInterval(minutes * 60) }
        let parts = value.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard var date = calendar.date(from: components) else { return nil }
        if date <= now { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
        return date
    }
}
