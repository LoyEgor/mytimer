import Foundation

enum DurationMapping {
    static let minimumDistance = 20.0
    static let exponent = 2.15

    static func progress(distance: Double, anchorDistance: Double) -> Double {
        let span = max(anchorDistance - minimumDistance, 1)
        return min(1, max(0, (distance - minimumDistance) / span))
    }

    static func minutes(distance: Double, anchorDistance: Double) -> Int? {
        guard distance >= minimumDistance else { return nil }
        let raw = 1 + 599 * pow(progress(distance: distance, anchorDistance: anchorDistance), exponent)
        if raw < 60 {
            return max(1, Int(raw.rounded()))
        }
        return max(60, Int((raw / 5).rounded()) * 5)
    }
}

enum Interaction {
    static let dragEngageGap = 10.0
}
