import AppKit
import ServiceManagement
@preconcurrency import UserNotifications

struct TimerRecord: Codable {
    let id: UUID
    let fireDate: Date
    // Optional so records created by older versions still decode.
    let createdAt: Date?
}

enum TimerLogic {
    static func expired(_ timers: [TimerRecord], now: Date) -> [TimerRecord] {
        timers.filter { $0.fireDate <= now }
    }
}

struct StatusSegmentData {
    let id: UUID
    let text: NSAttributedString
}

struct StatusDrawSegment {
    let id: UUID
    let rect: CGRect
    let text: NSAttributedString
}

struct StatusGeometry {
    let contentWidth: Double
    let iconSlot: CGRect
    let iconFrame: CGRect
    let segments: [StatusDrawSegment]
}

func statusGeometry(bounds: CGRect, segments: [StatusSegmentData], iconSize: CGSize) -> StatusGeometry {
    let widths = segments.map { ceil($0.text.size().width) }
    let textWidth = widths.reduce(0, +)
    let gaps = StatusLayout.timeGap * Double(max(0, segments.count - 1))
    let contentWidth = StatusLayout.iconSlot
        + (segments.isEmpty ? 0 : StatusLayout.iconGap + textWidth + gaps)
    let iconSlot = CGRect(
        x: bounds.maxX - StatusLayout.iconSlot,
        y: bounds.minY,
        width: StatusLayout.iconSlot,
        height: bounds.height)
    let iconFrame = CGRect(
        x: iconSlot.midX - iconSize.width / 2,
        y: iconSlot.midY - iconSize.height / 2,
        width: iconSize.width,
        height: iconSize.height)
    var rightEdge = iconSlot.minX - StatusLayout.iconGap
    var drawn: [StatusDrawSegment] = []
    for (segment, width) in zip(segments, widths) {
        let height = segment.text.size().height
        let rect = CGRect(
            x: rightEdge - width,
            y: bounds.midY - height / 2,
            width: width,
            height: height)
        drawn.append(StatusDrawSegment(id: segment.id, rect: rect, text: segment.text))
        rightEdge -= width + StatusLayout.timeGap
    }
    return StatusGeometry(
        contentWidth: contentWidth,
        iconSlot: iconSlot,
        iconFrame: iconFrame,
        segments: drawn)
}

// NSTextField intrinsic widths omit cell padding, so status text is measured and drawn directly.
final class StatusContentView: NSView {
    let iconView = NSImageView()
    var segments: [StatusSegmentData] = [] {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.needsDisplayOnBoundsChange = true
        addSubview(iconView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let geometry = currentGeometry()
        iconView.frame = geometry.iconFrame
        for segment in geometry.segments {
            segment.text.draw(at: segment.rect.origin)
        }
    }

    func currentGeometry() -> StatusGeometry {
        statusGeometry(bounds: bounds, segments: segments, iconSize: iconView.image?.size ?? .zero)
    }

    // Mouse events must reach the status bar button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum StatusLayout {
    static let iconSlot = 18.0
    static let iconGap = 6.0
    static let timeGap = 10.0
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let overlay = OverlayController()
    private var timers: [TimerRecord] = []
    private var updateTimer: Foundation.Timer?
    private var activityToken: NSObjectProtocol?
    private var trackingOrigin = NSPoint.zero
    private var dragEngageMaxY = 0.0
    private var dragging = false {
        didSet {
            if dragging {
                armedPress = nil
                currentPress = nil
                endStatusUpdateFreeze(refresh: true)
            }
        }
    }
    private var trackingActive = false
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var trackingWatchdog: Foundation.Timer?
    private var manualPanel: ManualTimerPanel?
    private var lastDragMinutes: Int?
    private var lastStatusTitle = ""
    private let verboseDebug = ProcessInfo.processInfo.environment["MYTIMER_DEBUG_VERBOSE"] == "1"
    private let statusContentView = StatusContentView()
    private var statusIconView: NSImageView { statusContentView.iconView }
    private var armedPress: (id: UUID, text: String, timestamp: TimeInterval)?
    private var currentPress: (id: UUID?, text: String?, timestamp: TimeInterval)?
    private var statusRefreshWorkItem: DispatchWorkItem?
    private var statusUpdatesFrozen = false
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
        // Foundation.Timer does not run during system sleep, so catch up on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)
        tick()
        writeFrame()
        DebugLog.shared.write("app launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeEventMonitors()
        statusRefreshWorkItem?.cancel()
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
    }

    @objc private func handleWake() {
        DebugLog.shared.write("system woke; re-ticking")
        tick()
    }

    private func configureStatusItem() {
        statusItem.autosaveName = "MyTimer"
        guard let button = statusItem.button else { return }
        let symbol = NSImage(systemSymbolName: "timer", accessibilityDescription: "MyTimer")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        symbol?.isTemplate = true
        statusIconView.image = symbol
        statusContentView.frame = button.bounds
        statusContentView.autoresizingMask = [.width, .height]
        button.addSubview(statusContentView)
        button.target = self
        button.action = #selector(statusMouseDown(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.toolTip = "MyTimer: drag to set a timer, click for menu, double-click or right-click a countdown to delete it"
    }

    @objc private func statusMouseDown(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent, let window = sender.window else { return }
        // Status-button locationInWindow is a fake center point on macOS 27.
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = statusContentView.convert(windowPoint, from: nil)
        let geometry = statusContentView.currentGeometry()
        let hit = countdownHit(at: point, geometry: geometry)
        logClickPress(x: point.x, geometry: geometry, hit: hit)
        if event.type == .rightMouseDown {
            armedPress = nil
            currentPress = nil
            endStatusUpdateFreeze(refresh: hit == nil)
            if let hit {
                DebugLog.shared.write(
                    "click result=right-click delete \(hit.text.string) id=\(hit.id.uuidString)")
                deleteTimer(id: hit.id, reason: "right-click")
            } else {
                DebugLog.shared.write("click result=menu")
                showMenu()
            }
            return
        }
        guard event.type == .leftMouseDown else { return }
        currentPress = (hit?.id, hit?.text.string, event.timestamp)
        if hit != nil { freezeStatusUpdates(after: event.timestamp) }
        beginTracking(sender)
    }

    private func countdownHit(at point: NSPoint, geometry: StatusGeometry) -> StatusDrawSegment? {
        guard point.x < geometry.iconSlot.minX else { return nil }
        return geometry.segments.first { $0.rect.insetBy(dx: -5, dy: -5).contains(point) }
    }

    private func logClickPress(x: Double, geometry: StatusGeometry, hit: StatusDrawSegment?) {
        let zones = geometry.segments.sorted { $0.rect.minX < $1.rect.minX }.map {
            "\($0.text.string):\(coordinate($0.rect.minX))-\(coordinate($0.rect.maxX))"
        }.joined(separator: ", ")
        let xText = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), x)
        DebugLog.shared.write(
            "click x=\(xText) zones=[\(zones)] iconZone>=\(coordinate(geometry.iconSlot.minX)) hit=\(hit?.text.string ?? "icon")")
    }

    private func coordinate(_ value: Double) -> String {
        String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func beginTracking(_ sender: NSStatusBarButton) {
        // Clear any monitors left by an interrupted cycle so a rapid re-press
        // always starts fresh instead of silently bailing.
        removeEventMonitors()
        trackingActive = false
        guard let window = sender.window else { return }
        let frame = window.frame
        let iconScreen = window.convertToScreen(statusIconView.convert(statusIconView.bounds, to: nil))
        trackingOrigin = NSPoint(x: iconScreen.midX, y: frame.midY)
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
            if !dragging {
                overlay.update(
                    origin: trackingOrigin, cursor: point, primary: "", secondary: "", cancelled: true,
                    tension: DurationMapping.progress(
                        distance: distance, anchorDistance: centerAnchorDistance()))
                if point.y < dragEngageMaxY {
                    dragging = true
                    DebugLog.shared.write("drag engaged")
                }
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
            if verboseDebug {
                DebugLog.shared.write("drag distance=\(Int(distance.rounded())) minutes=\(minutes)")
            }
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
            handleClickRelease()
        }
        dragging = false
        lastDragMinutes = nil
    }

    private func handleClickRelease() {
        guard let press = currentPress else { return }
        currentPress = nil
        if let id = press.id,
           let text = press.text,
           let previous = armedPress,
           previous.id == id,
           press.timestamp - previous.timestamp <= NSEvent.doubleClickInterval {
            armedPress = nil
            endStatusUpdateFreeze(refresh: false)
            DebugLog.shared.write("click result=double-click delete \(text) id=\(id.uuidString)")
            deleteTimer(id: id, reason: "double-click")
            return
        }
        if let id = press.id, let text = press.text {
            armedPress = (id, text, press.timestamp)
            DebugLog.shared.write("click result=armed \(text)")
        } else {
            armedPress = nil
            DebugLog.shared.write("click result=menu")
            showMenu()
        }
    }

    private func freezeStatusUpdates(after timestamp: TimeInterval) {
        statusRefreshWorkItem?.cancel()
        statusUpdatesFrozen = true
        // Keep drawn segments fixed while the second press is still eligible.
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.statusUpdatesFrozen = false
            self.updateStatusItem()
        }
        statusRefreshWorkItem = workItem
        let delay = max(0, timestamp + NSEvent.doubleClickInterval - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func endStatusUpdateFreeze(refresh: Bool) {
        statusRefreshWorkItem?.cancel()
        statusRefreshWorkItem = nil
        let wasFrozen = statusUpdatesFrozen
        statusUpdatesFrozen = false
        if refresh && wasFrozen { updateStatusItem() }
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
        menu.appearance = NSApp.effectiveAppearance
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
        let iconSlot = statusContentView.convert(statusContentView.currentGeometry().iconSlot, to: button)
        let anchorX = iconSlot.minX
        menu.popUp(positioning: nil, at: NSPoint(x: anchorX, y: button.bounds.maxY + 6), in: button)
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
        let timer = TimerRecord(id: UUID(), fireDate: fireDate, createdAt: Date())
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
            if let activityToken {
                ProcessInfo.processInfo.endActivity(activityToken)
                self.activityToken = nil
            }
            return
        }
        // App Nap can throttle a background accessory app's timer; the activity
        // token keeps 1s fires on time while the Mac is awake.
        if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated], reason: "Active countdown timers")
        }
        // An invalidated-but-non-nil timer would otherwise block rescheduling forever.
        if updateTimer?.isValid != true {
            updateTimer?.invalidate()
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
        let expired = TimerLogic.expired(timers, now: now)
        if !expired.isEmpty {
            timers.removeAll { $0.fireDate <= now }
            timersChanged()
            expired.forEach(fire)
        } else {
            updateStatusItem()
            syncTickTimer()
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
        timers = decoded
        // Route restore through the same choke point as every other mutation so
        // the ticker, display, and persisted store cannot fall out of sync.
        timersChanged()
        DebugLog.shared.write("timers restored count=\(timers.count)")
    }

    private func persistTimers() {
        if let data = try? JSONEncoder().encode(timers) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }

    private func updateStatusItem() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor]
        let newestFirst = orderedTimers()
        let values = newestFirst.map { TimeFormat.compactRemaining(until: $0.fireDate) }
        let joined = values.joined(separator: " ")
        if joined != lastStatusTitle {
            lastStatusTitle = joined
            if verboseDebug { DebugLog.shared.write("status title=\(joined)") }
        }
        guard !statusUpdatesFrozen else { return }

        statusContentView.segments = zip(newestFirst, values).map {
            StatusSegmentData(
                id: $0.0.id,
                text: NSAttributedString(string: $0.1, attributes: attributes))
        }
        let width = statusContentView.currentGeometry().contentWidth
        // Status-item length lands asynchronously; drawing must use the bounds AppKit eventually supplies.
        if statusItem.length != width { statusItem.length = width }
    }

    private func orderedTimers() -> [TimerRecord] {
        timers.sorted {
            switch ($0.createdAt, $1.createdAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return $0.id.uuidString < $1.id.uuidString
            }
        }
    }

    private func deleteTimer(id: UUID, reason: String) {
        guard timers.contains(where: { $0.id == id }) else { return }
        timers.removeAll { $0.id == id }
        timersChanged()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        DebugLog.shared.write("timer deleted by \(reason) id=\(id.uuidString)")
    }

    @objc private func handleDebugCommand(_ notification: Notification) {
        // The distributed-notification surface mutates real state; never accept
        // it outside an explicit debug run.
        guard DebugLog.shared.enabled else { return }
        guard let command = notification.userInfo?["command"] as? String else { return }
        if command == "add-seconds", let seconds = notification.userInfo?["seconds"] as? Double, seconds > 0 {
            addTimer(fireDate: Date().addingTimeInterval(seconds), source: "debug", detail: "seconds=\(seconds)")
        } else if command == "delete-id", let prefix = notification.userInfo?["prefix"] as? String, !prefix.isEmpty {
            timers.removeAll { $0.id.uuidString.hasPrefix(prefix.uppercased()) }
            timersChanged()
            DebugLog.shared.write("timer deleted by debug prefix=\(prefix)")
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
        let geometry = statusContentView.currentGeometry()
        if let window = statusItem.button?.window {
            let iconFrame = window.convertToScreen(statusContentView.convert(geometry.iconFrame, to: nil))
            DebugLog.shared.write("icon frame x=\(iconFrame.origin.x) width=\(iconFrame.width)")
        }
        for segment in geometry.segments.sorted(by: { $0.rect.minX < $1.rect.minX }) {
            DebugLog.shared.write(
                "segment \(segment.text.string) x=\(segment.rect.minX) w=\(segment.rect.width)")
        }
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
