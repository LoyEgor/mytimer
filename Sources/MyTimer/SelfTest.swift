import Foundation

func runSelfTest() -> Int32 {
    let anchor = 1000.0
    guard DurationMapping.minutes(distance: 19, anchorDistance: anchor) == nil else { print("FAIL threshold"); return 1 }
    guard DurationMapping.minutes(distance: 20, anchorDistance: anchor) == 1 else { print("FAIL minimum anchor"); return 1 }
    guard DurationMapping.minutes(distance: anchor, anchorDistance: anchor) == 600 else { print("FAIL center anchor"); return 1 }
    var previous = 0
    for distance in stride(from: 20.0, through: 2000.0, by: 1) {
        guard let value = DurationMapping.minutes(distance: distance, anchorDistance: anchor), value >= previous else {
            print("FAIL monotonic"); return 1
        }
        if value >= 60 && value % 5 != 0 { print("FAIL five-minute rounding"); return 1 }
        previous = value
    }

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    guard TimeFormat.compactRemaining(until: now.addingTimeInterval(30), now: now) == "30s" else { print("FAIL seconds format"); return 1 }
    guard TimeFormat.compactRemaining(until: now.addingTimeInterval(45 * 60), now: now) == "45m" else { print("FAIL minutes format"); return 1 }
    guard TimeFormat.compactRemaining(until: now.addingTimeInterval(599 * 60), now: now) == "9h59m" else { print("FAIL hours format"); return 1 }
    guard TimeFormat.compactRemaining(until: now.addingTimeInterval(120 * 60), now: now) == "2h00m" else { print("FAIL zero-pad format"); return 1 }
    guard TimeFormat.spokenDuration(minutes: 90) == "1 hr 30 min" else { print("FAIL spoken duration"); return 1 }

    guard let plain = TimeFormat.parseManualEntry("90", now: now),
          abs(plain.timeIntervalSince(now) - 5400) < 1 else { print("FAIL parse minutes"); return 1 }
    guard let clock = TimeFormat.parseManualEntry("17:30", now: now), clock > now,
          Calendar.current.component(.minute, from: clock) == 30 else { print("FAIL parse clock"); return 1 }
    guard TimeFormat.parseManualEntry("abc", now: now) == nil,
          TimeFormat.parseManualEntry("25:00", now: now) == nil,
          TimeFormat.parseManualEntry("-5", now: now) == nil else { print("FAIL parse rejects"); return 1 }

    guard DurationMapping.minutes(distance: 3000, anchorDistance: anchor) == 600 else { print("FAIL upper clamp"); return 1 }

    let samples = [50, 100, 200, 300, 400].compactMap { DurationMapping.minutes(distance: Double($0), anchorDistance: anchor) }
    print("PASS mapping minimum=1 center=600 clamp=600 monotonic=true samples=\(samples)")
    print("PASS formatting and manual-entry parsing")
    print("PASS state dragEngageGap=\(Int(Interaction.dragEngageGap)) cancelThreshold=\(Int(DurationMapping.minimumDistance))")
    return 0
}
