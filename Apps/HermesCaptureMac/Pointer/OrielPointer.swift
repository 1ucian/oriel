import AppKit
import QuartzCore

/// Oriel's own cursor: a drawn pointer that moves independently of the Mac's real one.
/// Remote moves only move this; the system pointer is borrowed for the instant of a click,
/// a drag or a scroll and put back where the owner left it.
@MainActor
final class OrielPointer {
    static let shared = OrielPointer()

    /// Where the drawn pointer's tip sits, in Quartz (top-left origin) display coordinates.
    private(set) var position: CGPoint?
    private let panel: NSPanel
    private let view: OrielPointerView
    private var hideWork: DispatchWorkItem?

    static let size = CGSize(width: 56, height: 56)
    /// The tip of the arrow inside the panel, from the panel's top-left.
    static let hotspot = CGPoint(x: 14, y: 12)

    private init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        view = OrielPointerView(frame: NSRect(origin: .zero, size: Self.size))
        panel.contentView = view
        panel.orderOut(nil)
    }

    /// Show the pointer at a Quartz point. Visible while the session is active; a long idle
    /// fades it so it never sits over the owner's work.
    func move(to quartzPoint: CGPoint, display: CGDirectDisplayID) {
        position = quartzPoint
        guard let origin = OrielPointerGeometry.panelOrigin(
            tip: quartzPoint,
            displayBounds: CGDisplayBounds(display),
            screenFrame: screenFrame(for: display),
            panelSize: Self.size,
            hotspot: Self.hotspot
        ) else { return }
        panel.setFrameOrigin(origin)
        if !panel.isVisible { view.alphaValue = 1 }
        panel.orderFrontRegardless()
        scheduleFade()
    }

    /// A ring that expands and fades at the tip: the click just happened here.
    func pulse() {
        guard panel.isVisible else { return }
        view.pulse()
        scheduleFade()
    }

    func hide() {
        hideWork?.cancel()
        position = nil
        panel.orderOut(nil)
    }

    private func scheduleFade() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.6
                self.view.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor in
                    if self.view.alphaValue == 0 { self.panel.orderOut(nil) }
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func screenFrame(for display: CGDirectDisplayID) -> NSRect? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }?.frame ?? NSScreen.main?.frame
    }
}

enum OrielPointerGeometry {
    /// Panel origin in AppKit screen coordinates (bottom-left origin) for a tip given in
    /// Quartz coordinates (top-left origin) of the same display.
    static func panelOrigin(
        tip: CGPoint,
        displayBounds: CGRect,
        screenFrame: NSRect?,
        panelSize: CGSize,
        hotspot: CGPoint
    ) -> NSPoint? {
        guard let screenFrame, !displayBounds.isEmpty else { return nil }
        let x = screenFrame.minX + (tip.x - displayBounds.minX) - hotspot.x
        let y = screenFrame.maxY - (tip.y - displayBounds.minY) - (panelSize.height - hotspot.y)
        return NSPoint(x: x, y: y)
    }
}

/// The drawing: a mint arrow with a petrol edge and a soft shadow, and a ring that pulses
/// on click. No badge, no text; the shape says it is not the Mac's own pointer.
private final class OrielPointerView: NSView {
    private let ring = CAShapeLayer()
    static let mint = NSColor(calibratedRed: 0x8F / 255, green: 0xD1 / 255, blue: 0xC6 / 255, alpha: 1)
    static let petrol = NSColor(calibratedRed: 0x16 / 255, green: 0x40 / 255, blue: 0x3F / 255, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        ring.fillColor = nil
        ring.strokeColor = Self.mint.withAlphaComponent(0.9).cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let tip = OrielPointer.hotspot
        let arrow = NSBezierPath()
        arrow.move(to: tip)
        arrow.line(to: NSPoint(x: tip.x, y: tip.y + 24))
        arrow.line(to: NSPoint(x: tip.x + 6.5, y: tip.y + 18.5))
        arrow.line(to: NSPoint(x: tip.x + 11, y: tip.y + 28))
        arrow.line(to: NSPoint(x: tip.x + 16, y: tip.y + 25.5))
        arrow.line(to: NSPoint(x: tip.x + 11.5, y: tip.y + 16))
        arrow.line(to: NSPoint(x: tip.x + 19.5, y: tip.y + 16))
        arrow.close()
        arrow.lineJoinStyle = .round

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        shadow.set()
        Self.mint.setFill()
        arrow.fill()
        NSGraphicsContext.restoreGraphicsState()

        Self.petrol.setStroke()
        arrow.lineWidth = 1.5
        arrow.stroke()
    }

    func pulse() {
        let tip = OrielPointer.hotspot
        let radius: CGFloat = 4
        ring.path = CGPath(ellipseIn: CGRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2), transform: nil)
        ring.frame = bounds
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.anchorPoint = CGPoint(x: tip.x / bounds.width, y: tip.y / bounds.height)
        ring.position = CGPoint(x: tip.x, y: tip.y)
        ring.bounds = bounds
        ring.add(group, forKey: "pulse")
    }
}
