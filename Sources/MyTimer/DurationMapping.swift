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

    static func minutes(distance: Double, anchorDistance: Double, step: Int = 1) -> Int? {
        guard distance >= minimumDistance else { return nil }
        let raw = 1 + 599 * pow(rawProgress(distance: distance, anchorDistance: anchorDistance), exponent)
        let rounded = Int((raw / Double(step)).rounded()) * step
        return max(max(1, step), rounded)
    }
}

enum Interaction {
    static let dragEngageGap = 10.0
    // Cursor speed (px/s) picks the snapping granularity: glide slowly for
    // single minutes, faster movement coarsens the step.
    static let fiveStepSpeed = 35.0
    static let tenStepSpeed = 90.0
    static let thirtyStepSpeed = 180.0

    static func step(forSpeed speed: Double) -> Int {
        if speed > thirtyStepSpeed { return 30 }
        if speed > tenStepSpeed { return 10 }
        if speed > fiveStepSpeed { return 5 }
        return 1
    }
}
