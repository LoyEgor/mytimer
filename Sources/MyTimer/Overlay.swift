import AppKit
import QuartzCore

final class OverlayView: NSView {
    struct Model {
        var originScreen = NSPoint.zero
        var cursorScreen = NSPoint.zero
        var primary = ""
        var secondary = ""
        var cancelled = false
        var tension = 0.0
    }

    static let snapDuration = 0.95
    static let cancelDuration = 0.18
    private static let retractDuration = 0.12
    private static let bubbleFadeDuration = 0.3
    private static let motionHoldDuration = 0.08
    private static let lineWidth = 3.2
    private static let backdropLineWidth = 9.0
    private static let primaryFont = NSFont.monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
    private static let secondaryFont = NSFont.systemFont(ofSize: 14, weight: .medium)

    private enum Phase {
        case dragging
        case snapping(CFTimeInterval)
        case cancelling(CFTimeInterval)
    }

    var model = Model() {
        didSet {
            if model.cursorScreen != oldValue.cursorScreen, isDragging {
                lastMotionTime = CACurrentMediaTime()
                ensureDisplayLink()
            }
            updateBubble()
            needsDisplay = true
        }
    }

    private let bubble = NSVisualEffectView()
    private let primaryLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")
    private var phase = Phase.dragging
    private var lastMotionTime = -1.0
    private var lastFrameTime = -1.0
    private var motionLevel = 0.0
    private var link: CADisplayLink?

    private var isDragging: Bool {
        if case .dragging = phase { return true }
        return false
    }

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bubble.material = .hudWindow
        bubble.state = .active
        bubble.blendingMode = .behindWindow
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 12
        bubble.isHidden = true
        primaryLabel.font = Self.primaryFont
        primaryLabel.textColor = .labelColor
        secondaryLabel.font = Self.secondaryFont
        secondaryLabel.textColor = .secondaryLabelColor
        bubble.addSubview(primaryLabel)
        bubble.addSubview(secondaryLabel)
        addSubview(bubble)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func resumeDragging() {
        phase = .dragging
    }

    func finish(created: Bool) {
        phase = created ? .snapping(CACurrentMediaTime()) : .cancelling(CACurrentMediaTime())
        updateBubble()
        ensureDisplayLink()
    }

    func teardown() {
        link?.invalidate()
        link = nil
    }

    private func ensureDisplayLink() {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let active: Bool
        switch phase {
        case .dragging:
            let moving = lastMotionTime > 0 && now - lastMotionTime < Self.motionHoldDuration
            let elapsed = lastFrameTime > 0 ? min(0.05, now - lastFrameTime) : 1.0 / 60.0
            let target = moving ? 1.0 : 0.0
            let rate = target > motionLevel ? 18.0 : 7.0
            let delta = max(-rate * elapsed, min(rate * elapsed, target - motionLevel))
            motionLevel += delta
            active = moving || motionLevel > 0.001
        case .snapping(let start):
            active = now - start < Self.snapDuration
        case .cancelling(let start):
            active = now - start < Self.cancelDuration
        }
        lastFrameTime = now
        needsDisplay = true
        updateBubble()
        if !active {
            lastFrameTime = -1
            teardown()
        }
    }

    private func updateBubble() {
        guard let window, !model.primary.isEmpty else {
            bubble.isHidden = true
            return
        }
        if case .cancelling = phase {
            bubble.isHidden = true
            return
        }
        let end = window.convertPoint(fromScreen: model.cursorScreen)
        guard bounds.insetBy(dx: -60, dy: -60).contains(end) else {
            bubble.isHidden = true
            return
        }
        primaryLabel.stringValue = model.primary
        secondaryLabel.stringValue = model.secondary
        primaryLabel.sizeToFit()
        secondaryLabel.sizeToFit()
        let width = max(primaryLabel.frame.width, secondaryLabel.frame.width) + 28
        let height = primaryLabel.frame.height + secondaryLabel.frame.height + 22
        primaryLabel.setFrameOrigin(NSPoint(x: 14, y: height - primaryLabel.frame.height - 9))
        secondaryLabel.setFrameOrigin(NSPoint(x: 14, y: 8))
        var x = end.x + 16
        var y = end.y - height / 2
        if x + width > bounds.maxX { x = end.x - width - 16 }
        x = max(8, min(x, bounds.maxX - width - 8))
        y = max(8, min(y, bounds.maxY - height - 8))
        bubble.frame = NSRect(x: x, y: y, width: width, height: height)
        if case .snapping(let start) = phase {
            bubble.alphaValue = max(0, 1 - (CACurrentMediaTime() - start) / Self.bubbleFadeDuration)
        } else {
            bubble.alphaValue = 1
        }
        bubble.isHidden = false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let window else { return }
        let start = window.convertPoint(fromScreen: model.originScreen)
        let end = window.convertPoint(fromScreen: model.cursorScreen)
        // Every screen's overlay gets the same model; only draw the parts that
        // actually land on this screen.
        let segment = NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
                             width: abs(end.x - start.x), height: abs(end.y - start.y))
            .insetBy(dx: -80, dy: -80)
        guard segment.intersects(bounds) else { return }
        let cursorVisible = bounds.insetBy(dx: -60, dy: -60).contains(end)
        let line = lineColor()
        let backdrop = backdropColor()
        switch phase {
        case .dragging:
            if cursorVisible {
                drawKnobBackdrop(context, at: end, color: backdrop, radius: 6,
                                 alpha: 1, expansion: 4 * motionLevel)
            }
            drawBand(context, from: start, to: end, color: line, backdropColor: backdrop,
                     widthScale: 1, alpha: 1, sagBoost: 1)
            drawAnchor(context, at: start, color: line, alpha: 1)
            if cursorVisible {
                drawKnob(context, at: end, color: line, radius: 6, alpha: 1)
            }
        case .snapping(let startTime):
            let t = CACurrentMediaTime() - startTime
            if t < Self.retractDuration {
                let x = t / Self.retractDuration
                let s = 1 - x * x
                let tip = NSPoint(x: start.x + (end.x - start.x) * s, y: start.y + (end.y - start.y) * s)
                let radius = 6 * (1 - 0.6 * x)
                drawKnobBackdrop(context, at: tip, color: backdrop, radius: radius, alpha: 1, expansion: 0)
                drawBand(context, from: start, to: tip, color: line, backdropColor: backdrop,
                         widthScale: 1 - 0.5 * x, alpha: 1, sagBoost: 1 - x)
                drawKnob(context, at: tip, color: line, radius: radius, alpha: 1)
            } else {
                let u = min(1, (t - Self.retractDuration) / (Self.snapDuration - Self.retractDuration))
                drawBloom(context, at: start, color: .controlAccentColor, progress: u)
                drawRipple(context, at: start, color: .controlAccentColor, progress: u)
            }
        case .cancelling(let startTime):
            let t = CACurrentMediaTime() - startTime
            let x = min(1, t / Self.cancelDuration)
            if cursorVisible {
                drawKnobBackdrop(context, at: end, color: backdrop, radius: 6,
                                 alpha: 1 - x, expansion: 4 * motionLevel)
            }
            drawBand(context, from: start, to: end, color: line, backdropColor: backdrop,
                     widthScale: 1, alpha: 1 - x, sagBoost: 1 + 2.5 * x)
            if cursorVisible {
                drawKnob(context, at: end, color: line, radius: 6, alpha: 1 - x)
            }
        }
    }

    // Black in light mode, white in dark mode; red only in the cancel zone.
    private func lineColor() -> NSColor {
        model.cancelled ? .systemRed : .labelColor
    }

    private func backdropColor() -> NSColor {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
    }

    private func drawBand(_ context: CGContext, from start: NSPoint, to end: NSPoint,
                          color: NSColor, backdropColor: NSColor,
                          widthScale: Double, alpha: Double, sagBoost: Double) {
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance > 1, alpha > 0 else { return }
        let sag = min(60, distance * 0.18) * pow(max(0, 1 - model.tension), 1.4) * sagBoost
        let control = NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - sag)
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)

        context.saveGState()
        context.setLineCap(.round)
        // The wide halo stripe only builds up as the pull gets longer.
        let haloAlpha = backdropAlpha * alpha
        if haloAlpha > 0.01 {
            context.addPath(path)
            context.setLineWidth(Self.backdropLineWidth * widthScale)
            context.setBlendMode(.copy)
            context.setStrokeColor(backdropColor.withAlphaComponent(haloAlpha).cgColor)
            context.strokePath()
            context.setBlendMode(.normal)
        }

        context.addPath(path)
        context.setLineWidth(max(1, Self.lineWidth * widthScale))
        context.replacePathWithStrokedPath()
        context.clip()
        let gradientColors = [color.withAlphaComponent(alpha).cgColor,
                              color.withAlphaComponent(0.55 * alpha).cgColor] as CFArray
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let gradient = CGGradient(colorsSpace: space, colors: gradientColors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: start, end: end,
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        context.restoreGState()
    }

    private func drawAnchor(_ context: CGContext, at point: NSPoint, color: NSColor, alpha: Double) {
        context.saveGState()
        context.setFillColor(color.withAlphaComponent(0.9 * alpha).cgColor)
        context.fillEllipse(in: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
        context.restoreGState()
    }

    private var backdropAlpha: Double {
        0.25 * min(1, model.tension * 1.3)
    }

    private func drawKnobBackdrop(_ context: CGContext, at point: NSPoint, color: NSColor,
                                  radius: Double, alpha: Double, expansion: Double) {
        let offset = (Self.backdropLineWidth - Self.lineWidth) / 2
        let backdropRadius = radius + offset + expansion
        guard alpha > 0, backdropRadius > 0.5 else { return }
        let rect = NSRect(x: point.x - backdropRadius, y: point.y - backdropRadius,
                          width: backdropRadius * 2, height: backdropRadius * 2)
        context.saveGState()
        context.setBlendMode(.copy)
        context.setFillColor(color.withAlphaComponent(backdropAlpha * alpha).cgColor)
        context.fillEllipse(in: rect)
        context.restoreGState()
    }

    private func drawKnob(_ context: CGContext, at point: NSPoint, color: NSColor,
                          radius: Double, alpha: Double) {
        guard alpha > 0, radius > 0.5 else { return }
        let rect = NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.saveGState()
        context.setShadow(offset: .zero, blur: 8, color: color.withAlphaComponent(0.5 * alpha).cgColor)
        context.setFillColor(color.withAlphaComponent(alpha).cgColor)
        context.fillEllipse(in: rect)
        context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.9 * alpha).cgColor)
        context.fillEllipse(in: rect.insetBy(dx: radius * 0.55, dy: radius * 0.55))
        context.restoreGState()
    }

    private func drawBloom(_ context: CGContext, at point: NSPoint, color: NSColor, progress: Double) {
        // Soft, slow "applied" reaction: a wide glow easing out well past the
        // menu bar rather than a quick blink.
        let eased = 1 - pow(1 - progress, 2)
        let alpha = 0.38 * pow(1 - progress, 1.4)
        guard alpha > 0.01 else { return }
        let radius = 14 + 96 * eased
        let stops = [color.withAlphaComponent(alpha).cgColor, color.withAlphaComponent(0).cgColor] as CFArray
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space, colors: stops, locations: [0, 1]) else { return }
        context.saveGState()
        context.drawRadialGradient(gradient, startCenter: point, startRadius: 0,
                                   endCenter: point, endRadius: radius, options: [])
        context.restoreGState()
    }

    private func drawRipple(_ context: CGContext, at point: NSPoint, color: NSColor, progress: Double) {
        let eased = 1 - pow(1 - progress, 2)
        let radius = 6 + 52 * eased
        let alpha = 0.3 * (1 - progress)
        context.saveGState()
        context.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
        context.setLineWidth(2.5 * (1 - progress) + 0.5)
        context.strokeEllipse(in: NSRect(x: point.x - radius, y: point.y - radius,
                                         width: radius * 2, height: radius * 2))
        context.setFillColor(color.withAlphaComponent(alpha * 0.6).cgColor)
        context.fillEllipse(in: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
        context.restoreGState()
    }
}

final class OverlayController {
    private var windows: [NSWindow] = []
    private var hideWorkItem: DispatchWorkItem?

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hideNow()
        }
    }

    // Window construction takes long enough to make the band visibly late if
    // deferred to the first drag event; build on mouse-down instead.
    func prewarm() {
        if windows.isEmpty { buildWindows() }
    }

    func update(origin: NSPoint, cursor: NSPoint, primary: String, secondary: String,
                cancelled: Bool, tension: Double) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        if windows.isEmpty { buildWindows() }
        let model = OverlayView.Model(originScreen: origin, cursorScreen: cursor, primary: primary,
                                      secondary: secondary, cancelled: cancelled, tension: tension)
        forEachView { view in
            view.resumeDragging()
            view.model = model
        }
    }

    func finish(created: Bool) {
        guard !windows.isEmpty else { return }
        forEachView { $0.finish(created: created) }
        let delay = (created ? OverlayView.snapDuration : OverlayView.cancelDuration) + 0.05
        let item = DispatchWorkItem { [weak self] in self?.hideNow() }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func hideNow() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        forEachView { $0.teardown() }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func buildWindows() {
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.orderFrontRegardless()
            return window
        }
    }

    private func forEachView(_ body: (OverlayView) -> Void) {
        for window in windows {
            if let view = window.contentView as? OverlayView { body(view) }
        }
    }
}
