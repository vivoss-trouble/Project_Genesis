import AppKit
import CoreGraphics
import Foundation

@_silgen_name("CGWindowListCreateImage")
func CGWindowListCreateImageLegacy(
    _ screenBounds: CGRect,
    _ listOption: UInt32,
    _ windowID: CGWindowID,
    _ imageOption: UInt32
) -> CGImage?

struct MapError: Error, CustomStringConvertible {
    let description: String
}

struct WindowInfo {
    let id: CGWindowID
    let owner: String
    let name: String
    let bounds: CGRect
}

struct Component {
    let kind: String
    let bbox: CGRect
    let pixelCenter: CGPoint
    let pixelCount: Int
    let confidence: Double
}

let debugPath = ProcessInfo.processInfo.environment["GENESIS_V71_DEBUG_PNG"]
    ?? "/tmp/genesis_v71_browser_fixture_debug.png"
let titleNeedle = (ProcessInfo.processInfo.environment["GENESIS_V71_WINDOW_TITLE"]
    ?? "Genesis v7.1 Browser Fixture").lowercased()
let ownerNeedles = (ProcessInfo.processInfo.environment["GENESIS_V71_WINDOW_OWNER"]
    ?? "Safari,Google Chrome,Chromium,Microsoft Edge,Arc")
    .split(separator: ",")
    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    .filter { !$0.isEmpty }

func emit(_ payload: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}

func findFixtureWindow() throws -> WindowInfo {
    guard let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else {
        throw MapError(description: "CGWindowListCopyWindowInfo returned no window list")
    }

    let candidates = rawList.compactMap { info -> WindowInfo? in
        guard
            let number = info[kCGWindowNumber as String] as? NSNumber,
            let owner = info[kCGWindowOwnerName as String] as? String,
            let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else {
            return nil
        }

        let name = info[kCGWindowName as String] as? String ?? ""
        let ownerMatches = ownerNeedles.contains { owner.lowercased().contains($0) }
        let titleMatches = name.lowercased().contains(titleNeedle)
        guard ownerMatches || titleMatches else {
            return nil
        }
        guard bounds.width >= 320, bounds.height >= 280 else {
            return nil
        }
        return WindowInfo(id: CGWindowID(number.uint32Value), owner: owner, name: name, bounds: bounds)
    }

    guard let window = candidates.sorted(by: { lhs, rhs in
        let lhsTitle = lhs.name.lowercased().contains(titleNeedle)
        let rhsTitle = rhs.name.lowercased().contains(titleNeedle)
        if lhsTitle != rhsTitle { return lhsTitle }
        return lhs.bounds.width * lhs.bounds.height > rhs.bounds.width * rhs.bounds.height
    }).first else {
        throw MapError(description: "Browser fixture window not found; open fixtures/v7/browser_fixture.html first")
    }
    return window
}

func captureWindow(_ window: WindowInfo) throws -> CGImage {
    guard let image = CGWindowListCreateImageLegacy(.null, 1 << 3, window.id, 1) else {
        throw MapError(description: "CGWindowListCreateImage returned null; Screen Recording permission may be required")
    }
    return image
}

func rgbaBuffer(from image: CGImage) throws -> (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int) {
    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw MapError(description: "failed to create RGBA bitmap context")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (bytes, width, height, bytesPerRow)
}

func pixelKind(r: UInt8, g: UInt8, b: UInt8, a: UInt8) -> String? {
    guard a >= 160 else { return nil }
    let red = Int(r)
    let green = Int(g)
    let blue = Int(b)

    if red <= 90 && green >= 150 && blue >= 175 {
        return "button-like"
    }
    if red <= 120 && green >= 145 && blue <= 150 {
        return "button-like"
    }
    if red >= 220 && green >= 220 && blue >= 220 {
        return "input-like"
    }
    if red >= 190 && green >= 120 && green <= 185 && blue <= 120 {
        return "scroll-container"
    }
    if red >= 200 && green <= 130 && blue >= 190 {
        return "async-target"
    }
    return nil
}

func detectComponents(bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> [Component] {
    var maskKinds = [String?](repeating: nil, count: width * height)
    for y in 0..<height {
        let rowStart = y * bytesPerRow
        for x in 0..<width {
            let offset = rowStart + x * 4
            maskKinds[y * width + x] = pixelKind(
                r: bytes[offset],
                g: bytes[offset + 1],
                b: bytes[offset + 2],
                a: bytes[offset + 3]
            )
        }
    }

    var visited = [Bool](repeating: false, count: width * height)
    var components: [Component] = []
    var queue: [(Int, Int)] = []

    for y in 0..<height {
        for x in 0..<width {
            let index = y * width + x
            guard let seedKind = maskKinds[index], !visited[index] else {
                continue
            }

            queue.removeAll(keepingCapacity: true)
            queue.append((x, y))
            visited[index] = true

            var countsByKind: [String: Int] = [seedKind: 0]
            var count = 0
            var sumX = 0.0
            var sumY = 0.0
            var minX = x
            var maxX = x
            var minY = y
            var maxY = y
            var cursor = 0

            while cursor < queue.count {
                let (cx, cy) = queue[cursor]
                cursor += 1
                guard let kind = maskKinds[cy * width + cx] else { continue }
                countsByKind[kind, default: 0] += 1
                count += 1
                sumX += Double(cx) + 0.5
                sumY += Double(cy) + 0.5
                minX = min(minX, cx)
                maxX = max(maxX, cx)
                minY = min(minY, cy)
                maxY = max(maxY, cy)

                for (nx, ny) in [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)] {
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let neighborIndex = ny * width + nx
                    if maskKinds[neighborIndex] != nil && !visited[neighborIndex] {
                        visited[neighborIndex] = true
                        queue.append((nx, ny))
                    }
                }
            }

            let bboxWidth = maxX - minX + 1
            let bboxHeight = maxY - minY + 1
            let area = bboxWidth * bboxHeight
            let fillRatio = area > 0 ? Double(count) / Double(area) : 0.0
            let widthRatio = Double(bboxWidth) / Double(width)
            let heightRatio = Double(bboxHeight) / Double(height)
            guard count >= 220 else { continue }
            guard bboxWidth >= 120, bboxHeight >= 80 else { continue }
            guard widthRatio >= 0.025 && widthRatio <= 0.72 else { continue }
            guard heightRatio >= 0.025 && heightRatio <= 0.45 else { continue }
            guard fillRatio >= 0.18 else { continue }

            let dominantKind = countsByKind.max { $0.value < $1.value }?.key ?? seedKind
            components.append(Component(
                kind: dominantKind,
                bbox: CGRect(x: minX, y: minY, width: bboxWidth, height: bboxHeight),
                pixelCenter: CGPoint(x: sumX / Double(count), y: sumY / Double(count)),
                pixelCount: count,
                confidence: min(0.99, max(0.0, fillRatio))
            ))
        }
    }

    return components.sorted {
        if abs($0.pixelCenter.y - $1.pixelCenter.y) > 18 {
            return $0.pixelCenter.y < $1.pixelCenter.y
        }
        return $0.pixelCenter.x < $1.pixelCenter.x
    }
}

func drawDebugOverlay(image: CGImage, components: [Component], path: String) throws {
    let size = NSSize(width: image.width, height: image.height)
    let nsImage = NSImage(cgImage: image, size: size)
    nsImage.lockFocus()
    NSColor.red.setStroke()
    NSColor.red.setFill()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
        .foregroundColor: NSColor.red,
        .backgroundColor: NSColor.black.withAlphaComponent(0.65),
    ]
    for (index, component) in components.enumerated() {
        let rect = NSRect(
            x: component.bbox.origin.x,
            y: CGFloat(image.height) - component.bbox.origin.y - component.bbox.height,
            width: component.bbox.width,
            height: component.bbox.height
        )
        let outline = NSBezierPath(rect: rect)
        outline.lineWidth = 2
        outline.stroke()
        let center = NSPoint(x: component.pixelCenter.x, y: CGFloat(image.height) - component.pixelCenter.y)
        NSBezierPath.strokeLine(from: NSPoint(x: center.x - 7, y: center.y), to: NSPoint(x: center.x + 7, y: center.y))
        NSBezierPath.strokeLine(from: NSPoint(x: center.x, y: center.y - 7), to: NSPoint(x: center.x, y: center.y + 7))
        let label = "\(index):\(component.kind)" as NSString
        label.draw(at: NSPoint(x: rect.minX + 3, y: rect.maxY - 18), withAttributes: attrs)
    }
    nsImage.unlockFocus()

    guard
        let tiff = nsImage.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        throw MapError(description: "failed to render debug overlay PNG")
    }
    try png.write(to: URL(fileURLWithPath: path))
}

do {
    let startedAt = Date()
    let window = try findFixtureWindow()
    let image = try captureWindow(window)
    let captureLatencyMs = Date().timeIntervalSince(startedAt) * 1000.0
    let buffer = try rgbaBuffer(from: image)
    let components = detectComponents(
        bytes: buffer.bytes,
        width: buffer.width,
        height: buffer.height,
        bytesPerRow: buffer.bytesPerRow
    )
    try drawDebugOverlay(image: image, components: components, path: debugPath)

    let scaleX = window.bounds.width > 0 ? Double(buffer.width) / window.bounds.width : 1.0
    let scaleY = window.bounds.height > 0 ? Double(buffer.height) / window.bounds.height : 1.0
    var kindCounters: [String: Int] = [:]
    var targets: [[String: Any]] = []
    for component in components {
        let localX = component.pixelCenter.x / scaleX
        let localY = component.pixelCenter.y / scaleY
        let kindIndex = kindCounters[component.kind, default: 0]
        kindCounters[component.kind] = kindIndex + 1
        targets.append([
            "target_id": "browser-\(component.kind)-\(kindIndex)",
            "control_kind": component.kind,
            "bbox": [
                "x": component.bbox.origin.x,
                "y": component.bbox.origin.y,
                "width": component.bbox.width,
                "height": component.bbox.height,
            ],
            "pixel_center": [
                "x": component.pixelCenter.x,
                "y": component.pixelCenter.y,
            ],
            "window_coregraphics_point": [
                "x": localX,
                "y": localY,
            ],
            "global_coregraphics_point": [
                "x": window.bounds.origin.x + localX,
                "y": window.bounds.origin.y + localY,
            ],
            "pixel_count": component.pixelCount,
            "confidence": component.confidence,
        ])
    }

    try emit([
        "event": "browser_fixture_readonly_map",
        "capture_scope": "window",
        "window_id": window.id,
        "window_owner": window.owner,
        "window_name": window.name,
        "window_bounds": [
            "x": window.bounds.origin.x,
            "y": window.bounds.origin.y,
            "width": window.bounds.width,
            "height": window.bounds.height,
        ],
        "physical_pixels": [
            "width": buffer.width,
            "height": buffer.height,
        ],
        "scale_x": scaleX,
        "scale_y": scaleY,
        "capture_latency_ms": captureLatencyMs,
        "target_count": targets.count,
        "control_kinds": Array(Set(targets.compactMap { $0["control_kind"] as? String })).sorted(),
        "targets": targets,
        "debug_overlay": debugPath,
        "posted": false,
    ])
} catch {
    try emit([
        "event": "browser_fixture_readonly_map",
        "status": "error",
        "error": "\(error)",
        "posted": false,
    ])
    exit(1)
}
