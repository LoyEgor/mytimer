import Foundation

enum DurationMapping {
    static let minimumDistance = 20.0
    static let exponent = 2.15

    // Unclamped: pulling past the screen-center anchor keeps growing the
    // duration along the same curve.
    static func rawProgress(distance: Double, anchorDistance: Double) -> Double {
        let span = max(anchorDistance - minimumDistance, 1)
        return max(0, (distance - minimumDistance) / span)
    }

    static func progress(distance: Double, anchorDistance: Double) -> Double {
        min(1, rawProgress(distance: distance, anchorDistance: anchorDistance))
    }

    static func minutes(distance: Double, anchorDistance: Double) -> Int? {
        guard distance >= minimumDistance else { return nil }
        let raw = 1 + 599 * pow(rawProgress(distance: distance, anchorDistance: anchorDistance), exponent)
        return max(1, Int(raw.rounded()))
    }
}

enum Interaction {
    static let dragEngageGap = 10.0
}
