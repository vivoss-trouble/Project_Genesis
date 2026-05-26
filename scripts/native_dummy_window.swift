import AppKit
import Foundation

struct Config {
    var selftest = false
    var windowX: Double = 160
    var windowY: Double = 160
    var windowWidth: Double = 420
    var windowHeight: Double = 260
    var targetX: Double = 150
    var targetY: Double = 95
    var targetWidth: Double = 120
    var targetHeight: Double = 70
    var markerSize: Double = 12
}

func parseConfig() -> Config {
    var config = Config()
    var index = 1
    let args = CommandLine.arguments
    while index < args.count {
        switch args[index] {
        case "--selftest":
            config.selftest = true
        case "--window-x":
            index += 1
            config.windowX = Double(args[safe: index] ?? "") ?? config.windowX
        case "--window-y":
            index += 1
            config.windowY = Double(args[safe: index] ?? "") ?? config.windowY
        default:
            fputs("unknown option: \(args[index])\n", stderr)
            exit(2)
        }
        index += 1
    }
    return config
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

func jsonLine(_ payload: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

func targetPayload(config: Config, event: String) -> [String: Any] {
    let globalTargetX = config.windowX + config.targetX
    let globalTargetY = config.windowY + config.targetY
    let centerX = globalTargetX + config.targetWidth / 2.0
    let centerY = globalTargetY + config.targetHeight / 2.0
    let markerX = centerX
    let markerY = centerY
    let screenHeight = NSScreen.main?.frame.height ?? 0.0
    return [
        "event": event,
        "target_id": "native-heal",
        "marker_id": "native-heal-marker",
        "marker_rgb": ["r": 255, "g": 0, "b": 255],
        "screen_logical_height": screenHeight,
        "window": [
            "x": config.windowX,
            "y": config.windowY,
            "width": config.windowWidth,
            "height": config.windowHeight,
        ],
        "target_logical_rect": [
            "x": config.targetX,
            "y": config.targetY,
            "width": config.targetWidth,
            "height": config.targetHeight,
        ],
        "target_global_logical_center": [
            "x": centerX,
            "y": centerY,
        ],
        "marker_global_logical_center": [
            "x": markerX,
            "y": markerY,
        ],
        "target_quartz_logical_center": [
            "x": centerX,
            "y": screenHeight > 0.0 ? screenHeight - centerY : centerY,
        ],
        "marker_quartz_logical_center": [
            "x": markerX,
            "y": screenHeight > 0.0 ? screenHeight - markerY : markerY,
        ],
    ]
}

func runtimeTargetPayload(config: Config, event: String, window: NSWindow, view: DummyView) -> [String: Any] {
    var payload = targetPayload(config: config, event: event)
    let targetWindowRect = view.convert(view.targetRect(), to: nil)
    let targetScreenRect = window.convertToScreen(targetWindowRect)
    let markerWindowRect = view.convert(view.markerRect(), to: nil)
    let markerScreenRect = window.convertToScreen(markerWindowRect)
    let centerX = targetScreenRect.midX
    let centerY = targetScreenRect.midY
    let markerCenterX = markerScreenRect.midX
    let markerCenterY = markerScreenRect.midY
    let screenHeight = NSScreen.main?.frame.height ?? 0.0

    payload["window_frame"] = [
        "x": window.frame.origin.x,
        "y": window.frame.origin.y,
        "width": window.frame.size.width,
        "height": window.frame.size.height,
    ]
    payload["target_appkit_screen_rect"] = [
        "x": targetScreenRect.origin.x,
        "y": targetScreenRect.origin.y,
        "width": targetScreenRect.size.width,
        "height": targetScreenRect.size.height,
    ]
    payload["target_appkit_screen_center"] = [
        "x": centerX,
        "y": centerY,
    ]
    payload["marker_appkit_screen_rect"] = [
        "x": markerScreenRect.origin.x,
        "y": markerScreenRect.origin.y,
        "width": markerScreenRect.size.width,
        "height": markerScreenRect.size.height,
    ]
    payload["marker_appkit_screen_center"] = [
        "x": markerCenterX,
        "y": markerCenterY,
    ]
    payload["target_coregraphics_screen_center"] = [
        "x": centerX,
        "y": screenHeight > 0.0 ? screenHeight - centerY : centerY,
    ]
    payload["marker_coregraphics_screen_center"] = [
        "x": markerCenterX,
        "y": screenHeight > 0.0 ? screenHeight - markerCenterY : markerCenterY,
    ]
    return payload
}

final class DummyView: NSView {
    let config: Config
    var hitCount = 0
    var trackingArea: NSTrackingArea?

    init(config: Config) {
        self.config = config
        super.init(frame: NSRect(x: 0, y: 0, width: config.windowWidth, height: config.windowHeight))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeAlways,
            .inVisibleRect,
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.08, alpha: 1.0).setFill()
        bounds.fill()

        let target = targetRect()
        let color = hitCount == 0
            ? NSColor(calibratedRed: 0.15, green: 0.9, blue: 0.35, alpha: 1.0)
            : NSColor(calibratedRed: 0.1, green: 0.55, blue: 1.0, alpha: 1.0)
        color.setFill()
        target.fill()

        NSColor.white.setStroke()
        NSBezierPath(rect: target).stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let label = hitCount == 0 ? "NATIVE HEAL" : "HIT \(hitCount)"
        label.draw(in: target.insetBy(dx: 4, dy: 24), withAttributes: attrs)

        let marker = markerRect()
        NSColor.black.setFill()
        marker.insetBy(dx: -2, dy: -2).fill()
        NSColor(calibratedRed: 1.0, green: 0.0, blue: 1.0, alpha: 1.0).setFill()
        marker.fill()

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.8, alpha: 1.0),
        ]
        "Genesis Native Dummy Window".draw(
            at: NSPoint(x: 18, y: config.windowHeight - 34),
            withAttributes: titleAttrs
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if targetRect().contains(point) {
            hitCount += 1
            jsonLine([
                "event": "native_dummy_hit",
                "target_id": "native-heal",
                "hit_count": hitCount,
                "local_point": ["x": point.x, "y": point.y],
            ])
            needsDisplay = true
        } else {
            jsonLine([
                "event": "native_dummy_miss",
                "local_point": ["x": point.x, "y": point.y],
            ])
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        jsonLine([
            "event": "native_dummy_mouse_moved",
            "inside_target": targetRect().contains(point),
            "local_point": ["x": point.x, "y": point.y],
        ])
    }

    override func mouseEntered(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        jsonLine([
            "event": "native_dummy_mouse_entered",
            "inside_target": targetRect().contains(point),
            "local_point": ["x": point.x, "y": point.y],
        ])
    }

    func targetRect() -> NSRect {
        NSRect(
            x: config.targetX,
            y: config.targetY,
            width: config.targetWidth,
            height: config.targetHeight
        )
    }

    func markerRect() -> NSRect {
        let target = targetRect()
        return NSRect(
            x: target.midX - config.markerSize / 2.0,
            y: target.midY - config.markerSize / 2.0,
            width: config.markerSize,
            height: config.markerSize
        )
    }
}

let config = parseConfig()
if config.selftest {
    jsonLine(targetPayload(config: config, event: "selftest"))
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let contentRect = NSRect(
    x: config.windowX,
    y: config.windowY,
    width: config.windowWidth,
    height: config.windowHeight
)
let window = NSWindow(
    contentRect: contentRect,
    styleMask: [.titled, .closable, .miniaturizable],
    backing: .buffered,
    defer: false
)
window.title = "Genesis Native Dummy"
window.isReleasedWhenClosed = false
window.level = .statusBar
window.acceptsMouseMovedEvents = true
let dummyView = DummyView(config: config)
window.contentView = dummyView
window.makeKeyAndOrderFront(nil)
window.makeMain()
window.makeFirstResponder(dummyView)
NSApp.activate(ignoringOtherApps: true)

jsonLine(runtimeTargetPayload(config: config, event: "ready", window: window, view: dummyView))
app.run()
