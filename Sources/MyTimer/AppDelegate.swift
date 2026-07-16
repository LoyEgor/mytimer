import AppKit
import ServiceManagement
@preconcurrency import UserNotifications

struct TimerRecord: Codable {
    let id: UUID
    let fireDate: Date
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let overlay = OverlayController()
    private var timers: [TimerRecord] = []
    private var updateTimer: Foundation.Timer?
    private var trackingOrigin = NSPoint.zero
    private var dragEngageMaxY = 0.0
    private var dragging = false
    private var trackingActive = false
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var trackingWatchdog: Foundation.Timer?
    private var manualPanel: ManualTimerPanel?
    private var lastDragMinutes: Int?
    private var lastStatusTitle = ""
    private let defaultsKey = "activeTimers"
    private let loginOptOutKey = "launchAtLoginOptOut"

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.shared.reset()
        configureStatusItem()
        restoreTimers()
        configureNotifications()
        syncLoginItem()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleDebugCommand(_:)), name: debugCommandNotification, object: nil)
        tick()
        writeFrame()
        DebugLog.shared.write("app launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeEventMonitors()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        let symbol = NSImage(systemSymbolName: "timer", accessibilityDescription: "MyTimer")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        symbol?.isTemplate = true
        button.image = symbol
        // Trailing keeps the icon glyph anchored while the countdown text
        // grows and shrinks to its left.
        button.imagePosition = .imageTrailing
        button.target = self
        button.action = #selector(statusMouseDown(_:))
        button.sendAction(on: [.leftMouseDown])
        button.toolTip = "MyTimer: drag to set a timer, click for menu"
    }

    @objc private func statusMouseDown(_ sender: NSStatusBarButton) {
        guard localMonitor == nil, NSApp.currentEvent != nil, let window = sender.window else { return }
        // The band grows from the icon glyph: with a countdown title the icon
        // sits in the trailing square of the button, not at its center.
        let frame = window.frame
        let iconCenterX = timers.isEmpty ? frame.midX : frame.maxX - frame.height / 2
        trackingOrigin = NSPoint(x: iconCenterX, y: frame.midY)
        dragEngageMaxY = frame.minY - Interaction.dragEngageGap
        overlay.prewarm()
        dragging = false
        trackingActive = true
        lastDragMinutes = nil
        sender.highlight(true)
        DebugLog.shared.write("mouse down origin=\(pointString(trackingOrigin))")
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleTrackingEvent(event)
            return nil
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleTrackingEvent(event)
        }
        // If the system swallows the mouse-up (screen lock, Mission Control),
        // no monitor ever fires again and tracking would wedge the status item.
        let watchdog = Foundation.Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.trackingActive else { return }
            if NSEvent.pressedMouseButtons & 1 == 0 { self.abortTracking() }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        trackingWatchdog = watchdog
    }

    private func abortTracking() {
        guard trackingActive else { return }
        trackingActive = false
        statusItem.button?.highlight(false)
        removeEventMonitors()
        overlay.finish(created: false)
        dragging = false
        lastDragMinutes = nil
        DebugLog.shared.write("tracking aborted: lost mouse-up")
    }

    private func handleTrackingEvent(_ event: NSEvent) {
        guard trackingActive else { return }
        let point = NSEvent.mouseLocation
        let distance = hypot(point.x - trackingOrigin.x, point.y - trackingOrigin.y)
        if event.type == .leftMouseDragged {
            if !dragging, point.y < dragEngageMaxY {
                dragging = true
                DebugLog.shared.write("drag engaged")
            }
            if dragging { updateDrag(at: point, distance: distance) }
        } else if event.type == .leftMouseUp {
            finishTracking(at: point, distance: distance)
        }
    }

    private func updateDrag(at point: NSPoint, distance: Double) {
        let anchor = centerAnchorDistance()
        let minutes = DurationMapping.minutes(distance: distance, anchorDistance: anchor)
        if minutes != lastDragMinutes {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            lastDragMinutes = minutes
        }
        let primary: String
        let secondary: String
        if let minutes {
            let fireDate = Date().addingTimeInterval(Double(minutes) * 60)
            primary = TimeFormat.spokenDuration(minutes: minutes)
            secondary = "fires at \(TimeFormat.fireTime(fireDate))"
            DebugLog.shared.write("drag distance=\(Int(distance.rounded())) minutes=\(minutes)")
        } else {
            primary = "Cancel"
            secondary = "Pull further to set a timer"
        }
        overlay.update(origin: trackingOrigin, cursor: point, primary: primary, secondary: secondary,
                       cancelled: minutes == nil,
                       tension: DurationMapping.progress(distance: distance, anchorDistance: anchor))
    }

    private func finishTracking(at point: NSPoint, distance: Double) {
        guard trackingActive else { return }
        trackingActive = false
        statusItem.button?.highlight(false)
        removeEventMonitors()
        if dragging {
            if let minutes = lastDragMinutes {
                overlay.finish(created: true)
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                addTimer(fireDate: Date().addingTimeInterval(Double(minutes) * 60),
                         source: "drag", detail: "minutes=\(minutes)")
            } else {
                overlay.finish(created: false)
                DebugLog.shared.write("drag cancelled")
            }
        } else {
            overlay.hideNow()
            DebugLog.shared.write("plain click")
            showMenu()
        }
        dragging = false
        lastDragMinutes = nil
    }

    private func removeEventMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        trackingWatchdog?.invalidate()
        trackingWatchdog = nil
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem.sectionHeader(title: "Timers"))
        if timers.isEmpty {
            let empty = NSMenuItem(title: "No active timers", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for timer in timers {
                let title = NSMutableAttributedString(
                    string: TimeFormat.fireTime(timer.fireDate),
                    attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)])
                title.append(NSAttributedString(
                    string: "   \(TimeFormat.remainingDescription(until: timer.fireDate)) left",
                    attributes: [.font: NSFont.menuFont(ofSize: 13),
                                 .foregroundColor: NSColor.secondaryLabelColor]))
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.attributedTitle = title
                item.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
                let submenu = NSMenu()
                let delete = NSMenuItem(title: "Delete", action: #selector(deleteTimer(_:)), keyEquivalent: "")
                delete.target = self
                delete.representedObject = timer.id.uuidString
                delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
                submenu.addItem(delete)
                item.submenu = submenu
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let add = NSMenuItem(title: "Add Timer…", action: #selector(showManualTimer), keyEquivalent: "")
        add.target = self
        add.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
        menu.addItem(add)
        if !timers.isEmpty {
            let clear = NSMenuItem(title: "Clear All Timers", action: #selector(clearAllTimers), keyEquivalent: "")
            clear.target = self
            clear.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            menu.addItem(clear)
        }
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MyTimer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 6), in: button)
    }

    @objc private func deleteTimer(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value) else { return }
        timers.removeAll { $0.id == id }
        timersChanged()
        DebugLog.shared.write("timer deleted id=\(id.uuidString)")
    }

    @objc private func clearAllTimers() {
        timers.removeAll()
        timersChanged()
        DebugLog.shared.write("timers cleared from menu")
    }

    @objc private func showManualTimer() {
        if manualPanel == nil {
            manualPanel = ManualTimerPanel { [weak self] date in self?.addTimer(fireDate: date, source: "manual") }
        }
        manualPanel?.show()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                UserDefaults.standard.set(true, forKey: loginOptOutKey)
            } else {
                UserDefaults.standard.set(false, forKey: loginOptOutKey)
                try service.register()
            }
        } catch {
            DebugLog.shared.write("login item toggle failed error=\(error.localizedDescription)")
        }
    }

    private func syncLoginItem() {
        guard SMAppService.mainApp.status != .enabled,
              !UserDefaults.standard.bool(forKey: loginOptOutKey) else { return }
        do {
            try SMAppService.mainApp.register()
            DebugLog.shared.write("login item registered")
        } catch {
            DebugLog.shared.write("login item registration failed error=\(error.localizedDescription)")
        }
    }

    private func addTimer(fireDate: Date, source: String, detail: String = "") {
        let timer = TimerRecord(id: UUID(), fireDate: fireDate)
        timers.append(timer)
        timersChanged()
        DebugLog.shared.write("timer created source=\(source) id=\(timer.id.uuidString) fire=\(TimeFormat.iso8601.string(from: fireDate)) \(detail)")
    }

    private func timersChanged() {
        timers.sort { $0.fireDate < $1.fireDate }
        persistTimers()
        updateStatusItem()
        syncTickTimer()
    }

    private func syncTickTimer() {
        if timers.isEmpty {
            updateTimer?.invalidate()
            updateTimer = nil
        } else if updateTimer == nil {
            let timer = Foundation.Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                self?.tick()
            }
            timer.tolerance = 0.2
            // .common keeps the countdown alive while the status menu is open.
            RunLoop.main.add(timer, forMode: .common)
            updateTimer = timer
        }
    }

    private func tick() {
        let now = Date()
        let expired = timers.filter { $0.fireDate <= now }
        if !expired.isEmpty {
            timers.removeAll { $0.fireDate <= now }
            timersChanged()
            expired.forEach(fire)
        } else {
            updateStatusItem()
        }
    }

    private func fire(_ timer: TimerRecord) {
        let soundPlayed: Bool
        if let sound = NSSound(named: "Glass") {
            soundPlayed = sound.play()
        } else {
            NSSound.beep()
            soundPlayed = true
        }
        DebugLog.shared.write("timer fired id=\(timer.id.uuidString) sound=\(soundPlayed)")
        let text = firedText(timer)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        let request = UNNotificationRequest(identifier: timer.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    DebugLog.shared.write("notification failed error=\(error.localizedDescription)")
                    self?.showFallbackAlert(for: timer)
                } else {
                    DebugLog.shared.write("notification delivered path=submitted")
                }
            }
        }
    }

    private func firedText(_ timer: TimerRecord) -> (title: String, body: String) {
        ("Time's up", "Timer for \(TimeFormat.fireTime(timer.fireDate)) finished.")
    }

    private func showFallbackAlert(for timer: TimerRecord) {
        NSApp.activate(ignoringOtherApps: true)
        let text = firedText(timer)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.body
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .informational
        alert.runModal()
        DebugLog.shared.write("fallback alert acknowledged")
    }

    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DebugLog.shared.write("notification authorization granted=\(granted) error=\(error?.localizedDescription ?? "none")")
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func restoreTimers() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        guard let decoded = try? JSONDecoder().decode([TimerRecord].self, from: data) else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            DebugLog.shared.write("timers store corrupted, cleared")
            return
        }
        timers = decoded.sorted { $0.fireDate < $1.fireDate }
        DebugLog.shared.write("timers restored count=\(timers.count)")
    }

    private func persistTimers() {
        if let data = try? JSONEncoder().encode(timers) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        if let next = timers.first {
            let title = TimeFormat.compactRemaining(until: next.fireDate)
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                             // Centers the text against the 15 pt symbol.
                             .baselineOffset: -1])
            if title != lastStatusTitle {
                lastStatusTitle = title
                DebugLog.shared.write("status title=\(title)")
            }
        } else {
            button.title = ""
            lastStatusTitle = ""
        }
    }

    @objc private func handleDebugCommand(_ notification: Notification) {
        // The distributed-notification surface mutates real state; never accept
        // it outside an explicit debug run.
        guard DebugLog.shared.enabled else { return }
        guard let command = notification.userInfo?["command"] as? String else { return }
        if command == "add-seconds", let seconds = notification.userInfo?["seconds"] as? Double, seconds > 0 {
            addTimer(fireDate: Date().addingTimeInterval(seconds), source: "debug", detail: "seconds=\(seconds)")
        } else if command == "clear" {
            timers.removeAll()
            timersChanged()
            DebugLog.shared.write("timers cleared")
        } else if command == "write-frame" {
            writeFrame()
        }
    }

    private func writeFrame() {
        guard let frame = statusItem.button?.window?.frame else {
            DebugLog.shared.write("status frame unavailable")
            return
        }
        DebugLog.shared.write("status frame x=\(frame.origin.x) y=\(frame.origin.y) width=\(frame.width) height=\(frame.height)")
    }

    private func centerAnchorDistance() -> Double {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(trackingOrigin) }) ?? NSScreen.main else { return 700 }
        return max(DurationMapping.minimumDistance + 1,
                   hypot(screen.frame.midX - trackingOrigin.x, screen.frame.midY - trackingOrigin.y))
    }

    private func pointString(_ point: NSPoint) -> String {
        "\(Int(point.x.rounded())),\(Int(point.y.rounded()))"
    }
}
