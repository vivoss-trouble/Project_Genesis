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
    var markerSize: Double = 28
}

struct TargetSpec {
    let id: String
    let label: String
    let rect: NSRect
}

func buildTargetSpecs(config: Config) -> [TargetSpec] {
    [
        TargetSpec(
            id: "native-heal-a",
            label: "HEAL A",
            rect: NSRect(x: 40, y: config.targetY, width: config.targetWidth, height: config.targetHeight)
        ),
        TargetSpec(
            id: "native-heal-b",
            label: "HEAL B",
            rect: NSRect(x: config.targetX, y: config.targetY, width: config.targetWidth, height: config.targetHeight)
        ),
        TargetSpec(
            id: "native-heal-c",
            label: "HEAL C",
            rect: NSRect(x: 260, y: config.targetY, width: config.targetWidth, height: config.targetHeight)
        ),
    ]
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
    let primaryTarget = buildTargetSpecs(config: config)[1]
    let globalTargetX = config.windowX + primaryTarget.rect.origin.x
    let globalTargetY = config.windowY + primaryTarget.rect.origin.y
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
        "target_ids": buildTargetSpecs(config: config).map { $0.id },
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

    payload["window_number"] = window.windowNumber
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
    payload["targets"] = view.targetSpecs.map { target in
        let targetWindowRect = view.convert(target.rect, to: nil)
        let targetScreenRect = window.convertToScreen(targetWindowRect)
        let markerWindowRect = view.convert(view.markerRect(for: target.rect), to: nil)
        let markerScreenRect = window.convertToScreen(markerWindowRect)
        return [
            "id": target.id,
            "label": target.label,
            "target_appkit_screen_center": [
                "x": targetScreenRect.midX,
                "y": targetScreenRect.midY,
            ],
            "target_coregraphics_screen_center": [
                "x": targetScreenRect.midX,
                "y": screenHeight > 0.0 ? screenHeight - targetScreenRect.midY : targetScreenRect.midY,
            ],
            "marker_appkit_screen_center": [
                "x": markerScreenRect.midX,
                "y": markerScreenRect.midY,
            ],
            "marker_coregraphics_screen_center": [
                "x": markerScreenRect.midX,
                "y": screenHeight > 0.0 ? screenHeight - markerScreenRect.midY : markerScreenRect.midY,
            ],
            "target_logical_rect": [
                "x": target.rect.origin.x,
                "y": target.rect.origin.y,
                "width": target.rect.size.width,
                "height": target.rect.size.height,
            ],
        ]
    }
    return payload
}

final class DummyView: NSView {
    let config: Config
    let targetSpecs: [TargetSpec]
    var hitCounts: [String: Int] = [:]
    var trackingArea: NSTrackingArea?

    init(config: Config) {
        self.config = config
        self.targetSpecs = buildTargetSpecs(config: config)
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

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        for target in targetSpecs {
            let hitCount = hitCounts[target.id, default: 0]
            let color = hitCount == 0
                ? NSColor(calibratedRed: 0.15, green: 0.9, blue: 0.35, alpha: 1.0)
                : NSColor(calibratedRed: 0.1, green: 0.55, blue: 1.0, alpha: 1.0)
            color.setFill()
            target.rect.fill()

            NSColor.white.setStroke()
            NSBezierPath(rect: target.rect).stroke()

            let label = hitCount == 0 ? target.label : "HIT \(hitCount)"
            label.draw(in: target.rect.insetBy(dx: 4, dy: 24), withAttributes: attrs)

            let marker = markerRect(for: target.rect)
            NSColor.black.setFill()
            marker.insetBy(dx: -2, dy: -2).fill()
            NSColor(calibratedRed: 1.0, green: 0.0, blue: 1.0, alpha: 1.0).setFill()
            marker.fill()
        }

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
        if let target = targetSpecs.first(where: { $0.rect.contains(point) }) {
            hitCounts[target.id, default: 0] += 1
            jsonLine([
                "event": "native_dummy_hit",
                "target_id": target.id,
                "hit_count": hitCounts[target.id, default: 0],
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
        let insideTargets = targetSpecs.filter { $0.rect.contains(point) }.map { $0.id }
        jsonLine([
            "event": "native_dummy_mouse_moved",
            "inside_target": !insideTargets.isEmpty,
            "inside_targets": insideTargets,
            "local_point": ["x": point.x, "y": point.y],
        ])
    }

    override func mouseEntered(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let insideTargets = targetSpecs.filter { $0.rect.contains(point) }.map { $0.id }
        jsonLine([
            "event": "native_dummy_mouse_entered",
            "inside_target": !insideTargets.isEmpty,
            "inside_targets": insideTargets,
            "local_point": ["x": point.x, "y": point.y],
        ])
    }

    func targetRect() -> NSRect {
        targetSpecs[1].rect
    }

    func markerRect() -> NSRect {
        markerRect(for: targetRect())
    }

    func markerRect(for target: NSRect) -> NSRect {
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
window.level = .floating
window.acceptsMouseMovedEvents = true
let dummyView = DummyView(config: config)
window.contentView = dummyView
window.makeKeyAndOrderFront(nil)
window.makeMain()
window.makeFirstResponder(dummyView)
NSApp.activate(ignoringOtherApps: true)

jsonLine(runtimeTargetPayload(config: config, event: "ready", window: window, view: dummyView))
app.run()
