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

struct ShadowMapError: Error, CustomStringConvertible {
    let description: String
}

struct WindowInfo {
    let id: CGWindowID
    let owner: String
    let name: String
    let bounds: CGRect
}

struct RawComponent {
    let kind: String
    var bbox: CGRect
    var pixelCenter: CGPoint
    var pixelCount: Int
    var confidence: Double
}

let env = ProcessInfo.processInfo.environment
let debugPath = env["GENESIS_V81_DEBUG_PNG"] ?? "/tmp/genesis_v81_shadow_map.png"
let titleNeedle = (env["GENESIS_V81_WINDOW_TITLE"] ?? "Genesis v8.1 Shadow Mapping Sample").lowercased()
let ownerNeedles = (env["GENESIS_V81_WINDOW_OWNER"] ?? "Safari,Google Chrome,Chromium,Microsoft Edge,Arc")
    .split(separator: ",")
    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    .filter { !$0.isEmpty }

func emit(_ payload: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}

func findBrowserWindow() throws -> WindowInfo {
    guard let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else {
        throw ShadowMapError(description: "CGWindowListCopyWindowInfo returned no window list")
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
        guard ownerMatches || titleMatches else { return nil }
        guard bounds.width >= 480, bounds.height >= 360 else { return nil }
        return WindowInfo(id: CGWindowID(number.uint32Value), owner: owner, name: name, bounds: bounds)
    }

    guard let window = candidates.sorted(by: { lhs, rhs in
        let lhsTitle = lhs.name.lowercased().contains(titleNeedle)
        let rhsTitle = rhs.name.lowercased().contains(titleNeedle)
        if lhsTitle != rhsTitle { return lhsTitle }
        return lhs.bounds.width * lhs.bounds.height > rhs.bounds.width * rhs.bounds.height
    }).first else {
        throw ShadowMapError(description: "open web browser window not found for title '\(titleNeedle)'")
    }
    return window
}

func captureWindow(_ window: WindowInfo) throws -> CGImage {
    guard let image = CGWindowListCreateImageLegacy(.null, 1 << 3, window.id, 1) else {
        throw ShadowMapError(description: "CGWindowListCreateImage returned null; Screen Recording permission may be required")
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
        throw ShadowMapError(description: "failed to create RGBA bitmap context")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (bytes, width, height, bytesPerRow)
}

func pixelKind(r: UInt8, g: UInt8, b: UInt8, a: UInt8) -> String? {
    guard a >= 160 else { return nil }
    let red = Int(r)
    let green = Int(g)
    let blue = Int(b)

    if red <= 55 && green <= 70 && blue <= 95 {
        return "code-block"
    }
    if red >= 235 && green >= 185 && green <= 245 && blue <= 190 {
        return "scroll-region"
    }
    if red >= 90 && red <= 160 && green <= 95 && blue >= 150 {
        return "heading"
    }
    if red <= 95 && green >= 80 && green <= 150 && blue >= 175 {
        return "button-like"
    }
    if red <= 70 && green >= 75 && green <= 150 && blue >= 145 {
        return "link-like"
    }
    return nil
}

func detectRawComponents(bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> [RawComponent] {
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
    var components: [RawComponent] = []
    var queue: [(Int, Int)] = []

    for y in 0..<height {
        for x in 0..<width {
            let index = y * width + x
            guard let seedKind = maskKinds[index], !visited[index] else { continue }

            queue.removeAll(keepingCapacity: true)
            queue.append((x, y))
            visited[index] = true

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
                    if maskKinds[neighborIndex] == seedKind && !visited[neighborIndex] {
                        visited[neighborIndex] = true
                        queue.append((nx, ny))
                    }
                }
            }

            let bboxWidth = maxX - minX + 1
            let bboxHeight = maxY - minY + 1
            guard count >= 8, bboxWidth >= 2, bboxHeight >= 2 else { continue }
            let area = max(1, bboxWidth * bboxHeight)
            components.append(RawComponent(
                kind: seedKind,
                bbox: CGRect(x: minX, y: minY, width: bboxWidth, height: bboxHeight),
                pixelCenter: CGPoint(x: sumX / Double(count), y: sumY / Double(count)),
                pixelCount: count,
                confidence: min(0.99, Double(count) / Double(area))
            ))
        }
    }

    return components
}

func mergeTextComponents(_ components: [RawComponent], kind: String, xGap: CGFloat, yGap: CGFloat) -> [RawComponent] {
    var parts = components.filter { $0.kind == kind }
        .sorted {
            if abs($0.bbox.midY - $1.bbox.midY) > yGap {
                return $0.bbox.midY < $1.bbox.midY
            }
            return $0.bbox.minX < $1.bbox.minX
        }
    var merged: [RawComponent] = []

    while !parts.isEmpty {
        var current = parts.removeFirst()
        var changed = true
        while changed {
            changed = false
            var remaining: [RawComponent] = []
            for part in parts {
                let verticalClose = abs(part.bbox.midY - current.bbox.midY) <= yGap
                let horizontalClose = part.bbox.minX <= current.bbox.maxX + xGap
                    && part.bbox.maxX >= current.bbox.minX - xGap
                if verticalClose && horizontalClose {
                    current = union(current, part)
                    changed = true
                } else {
                    remaining.append(part)
                }
            }
            parts = remaining
        }
        merged.append(current)
    }

    return merged
}

func union(_ lhs: RawComponent, _ rhs: RawComponent) -> RawComponent {
    let total = max(1, lhs.pixelCount + rhs.pixelCount)
    let lhsWeight = Double(lhs.pixelCount)
    let rhsWeight = Double(rhs.pixelCount)
    let rect = lhs.bbox.union(rhs.bbox)
    let center = CGPoint(
        x: (lhs.pixelCenter.x * lhsWeight + rhs.pixelCenter.x * rhsWeight) / Double(total),
        y: (lhs.pixelCenter.y * lhsWeight + rhs.pixelCenter.y * rhsWeight) / Double(total)
    )
    let area = max(1.0, rect.width * rect.height)
    return RawComponent(
        kind: lhs.kind,
        bbox: rect,
        pixelCenter: center,
        pixelCount: total,
        confidence: min(0.99, Double(total) / area)
    )
}

func postProcess(_ raw: [RawComponent], width: Int, height: Int) -> [RawComponent] {
    let filledKinds = raw.filter { component in
        let widthRatio = component.bbox.width / CGFloat(width)
        let heightRatio = component.bbox.height / CGFloat(height)
        let area = component.bbox.width * component.bbox.height
        switch component.kind {
        case "button-like":
            return component.pixelCount >= 900
                && component.bbox.width >= 90
                && component.bbox.height >= 34
                && widthRatio <= 0.45
        case "code-block":
            return component.pixelCount >= 4_000
                && component.bbox.width >= 240
                && component.bbox.height >= 80
                && widthRatio <= 0.90
        case "scroll-region":
            return component.pixelCount >= 6_000
                && component.bbox.width >= 280
                && component.bbox.height >= 120
                && widthRatio <= 0.90
                && heightRatio <= 0.55
        default:
            return area >= 1_000 && false
        }
    }

    let headings = mergeTextComponents(raw, kind: "heading", xGap: 42, yGap: 30)
        .filter { $0.pixelCount >= 150 && $0.bbox.width >= 140 && $0.bbox.height >= 26 }
    let links = mergeTextComponents(raw, kind: "link-like", xGap: 28, yGap: 18)
        .filter { $0.pixelCount >= 80 && $0.bbox.width >= 90 && $0.bbox.height >= 12 }

    return (headings + links + filledKinds).sorted {
        if abs($0.pixelCenter.y - $1.pixelCenter.y) > 18 {
            return $0.pixelCenter.y < $1.pixelCenter.y
        }
        return $0.pixelCenter.x < $1.pixelCenter.x
    }
}

func drawDebugOverlay(image: CGImage, components: [RawComponent], path: String) throws {
    let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    nsImage.lockFocus()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
        .foregroundColor: NSColor.white,
        .backgroundColor: NSColor.black.withAlphaComponent(0.72),
    ]

    for (index, component) in components.enumerated() {
        let color: NSColor
        switch component.kind {
        case "heading": color = .systemPurple
        case "link-like": color = .systemBlue
        case "button-like": color = .systemGreen
        case "code-block": color = .systemRed
        case "scroll-region": color = .systemOrange
        default: color = .systemPink
        }
        color.setStroke()
        color.setFill()
        let rect = NSRect(
            x: component.bbox.origin.x,
            y: CGFloat(image.height) - component.bbox.origin.y - component.bbox.height,
            width: component.bbox.width,
            height: component.bbox.height
        )
        let outline = NSBezierPath(rect: rect)
        outline.lineWidth = 3
        outline.stroke()
        let center = NSPoint(x: component.pixelCenter.x, y: CGFloat(image.height) - component.pixelCenter.y)
        NSBezierPath.strokeLine(from: NSPoint(x: center.x - 8, y: center.y), to: NSPoint(x: center.x + 8, y: center.y))
        NSBezierPath.strokeLine(from: NSPoint(x: center.x, y: center.y - 8), to: NSPoint(x: center.x, y: center.y + 8))
        let label = "\(index):\(component.kind)" as NSString
        label.draw(at: NSPoint(x: rect.minX + 4, y: rect.maxY - 19), withAttributes: attrs)
    }
    nsImage.unlockFocus()

    guard
        let tiff = nsImage.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        throw ShadowMapError(description: "failed to render debug overlay PNG")
    }
    try png.write(to: URL(fileURLWithPath: path))
}

do {
    let startedAt = Date()
    let window = try findBrowserWindow()
    let image = try captureWindow(window)
    let captureLatencyMs = Date().timeIntervalSince(startedAt) * 1000.0
    let buffer = try rgbaBuffer(from: image)
    let raw = detectRawComponents(
        bytes: buffer.bytes,
        width: buffer.width,
        height: buffer.height,
        bytesPerRow: buffer.bytesPerRow
    )
    let components = postProcess(raw, width: buffer.width, height: buffer.height)
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
            "target_id": "shadow-\(component.kind)-\(kindIndex)",
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
        "event": "open_web_shadow_map",
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
        "taxonomy_version": "v8.1-shadow-taxonomy",
        "posted": false,
        "os_driver_active": false,
    ])
} catch {
    try emit([
        "event": "open_web_shadow_map",
        "status": "error",
        "error": "\(error)",
        "posted": false,
        "os_driver_active": false,
    ])
    exit(1)
}
