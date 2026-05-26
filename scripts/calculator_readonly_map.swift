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

struct JsonError: Error, CustomStringConvertible {
    let description: String
}

struct WindowInfo {
    let id: CGWindowID
    let owner: String
    let name: String
    let bounds: CGRect
}

struct Component {
    let bbox: CGRect
    let pixelCenter: CGPoint
    let pixelCount: Int
    let confidence: Double
}

let debugPath = ProcessInfo.processInfo.environment["GENESIS_V61_DEBUG_PNG"]
    ?? "/tmp/genesis_v61_debug.png"
let ownerNeedles = (ProcessInfo.processInfo.environment["GENESIS_V61_WINDOW_OWNER"] ?? "Calculator,计算器")
    .split(separator: ",")
    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    .filter { !$0.isEmpty }

func emit(_ payload: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}

func findCalculatorWindow() throws -> WindowInfo {
    guard let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else {
        throw JsonError(description: "CGWindowListCopyWindowInfo returned no window list")
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
        let haystack = "\(owner) \(name)".lowercased()
        guard ownerNeedles.contains(where: { haystack.contains($0) }) else {
            return nil
        }
        guard bounds.width >= 160, bounds.height >= 160 else {
            return nil
        }
        return WindowInfo(id: CGWindowID(number.uint32Value), owner: owner, name: name, bounds: bounds)
    }

    guard let window = candidates.sorted(by: { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }).first else {
        throw JsonError(description: "Calculator window not found; open Calculator before running v6.1 mapping")
    }
    return window
}

func captureWindow(_ window: WindowInfo) throws -> CGImage {
    guard let image = CGWindowListCreateImageLegacy(.null, 1 << 3, window.id, 1) else {
        throw JsonError(description: "CGWindowListCreateImage returned null for Calculator window; Screen Recording permission may be required")
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
        throw JsonError(description: "failed to create RGBA bitmap context")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (bytes, width, height, bytesPerRow)
}

func isButtonPixel(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> Bool {
    guard a >= 160 else { return false }
    let red = Int(r)
    let green = Int(g)
    let blue = Int(b)
    let maxChannel = max(red, max(green, blue))
    let minChannel = min(red, min(green, blue))
    let brightness = (red + green + blue) / 3
    let saturation = maxChannel - minChannel

    if red >= 180 && green >= 90 && green <= 190 && blue <= 80 {
        return true
    }
    if brightness >= 48 && brightness <= 210 && saturation <= 80 {
        return true
    }
    return false
}

func detectComponents(bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> [Component] {
    let minY = max(0, Int(Double(height) * 0.28))
    var mask = [Bool](repeating: false, count: width * height)
    for y in minY..<height {
        let rowStart = y * bytesPerRow
        for x in 0..<width {
            let offset = rowStart + x * 4
            if isButtonPixel(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]) {
                mask[y * width + x] = true
            }
        }
    }

    var visited = [Bool](repeating: false, count: mask.count)
    var components: [Component] = []
    var queue: [(Int, Int)] = []

    for y in minY..<height {
        for x in 0..<width {
            let index = y * width + x
            if !mask[index] || visited[index] {
                continue
            }
            queue.removeAll(keepingCapacity: true)
            queue.append((x, y))
            visited[index] = true

            var count = 0
            var sumX = 0.0
            var sumY = 0.0
            var minX = x
            var maxX = x
            var minYComponent = y
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
                minYComponent = min(minYComponent, cy)
                maxY = max(maxY, cy)

                let neighbors = [
                    (cx - 1, cy),
                    (cx + 1, cy),
                    (cx, cy - 1),
                    (cx, cy + 1),
                ]
                for (nx, ny) in neighbors {
                    guard nx >= 0, ny >= minY, nx < width, ny < height else { continue }
                    let neighborIndex = ny * width + nx
                    if mask[neighborIndex] && !visited[neighborIndex] {
                        visited[neighborIndex] = true
                        queue.append((nx, ny))
                    }
                }
            }

            let bboxWidth = maxX - minX + 1
            let bboxHeight = maxY - minYComponent + 1
            let area = bboxWidth * bboxHeight
            let fillRatio = area > 0 ? Double(count) / Double(area) : 0.0
            let widthRatio = Double(bboxWidth) / Double(width)
            let heightRatio = Double(bboxHeight) / Double(height)
            let aspect = Double(bboxWidth) / Double(max(1, bboxHeight))

            guard count >= 200 else { continue }
            guard widthRatio >= 0.08 && widthRatio <= 0.38 else { continue }
            guard heightRatio >= 0.06 && heightRatio <= 0.24 else { continue }
            guard aspect >= 0.75 && aspect <= 2.8 else { continue }
            guard fillRatio >= 0.35 else { continue }

            components.append(Component(
                bbox: CGRect(x: minX, y: minYComponent, width: bboxWidth, height: bboxHeight),
                pixelCenter: CGPoint(x: sumX / Double(count), y: sumY / Double(count)),
                pixelCount: count,
                confidence: min(0.99, max(0.0, fillRatio))
            ))
        }
    }

    return components.sorted {
        if abs($0.pixelCenter.y - $1.pixelCenter.y) > 12 {
            return $0.pixelCenter.y < $1.pixelCenter.y
        }
        return $0.pixelCenter.x < $1.pixelCenter.x
    }
}

func groupRows(_ components: [Component]) -> [[Component]] {
    var rows: [[Component]] = []
    for component in components {
        if let last = rows.indices.last {
            let avgY = rows[last].map { $0.pixelCenter.y }.reduce(0, +) / Double(rows[last].count)
            if abs(component.pixelCenter.y - avgY) <= max(14.0, component.bbox.height * 0.45) {
                rows[last].append(component)
                rows[last].sort { $0.pixelCenter.x < $1.pixelCenter.x }
                continue
            }
        }
        rows.append([component])
    }
    return rows
}

func drawDebugOverlay(image: CGImage, rows: [[Component]], path: String) throws {
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
    for (rowIndex, row) in rows.enumerated() {
        for (colIndex, component) in row.enumerated() {
            let rect = NSRect(
                x: component.bbox.origin.x,
                y: CGFloat(image.height) - component.bbox.origin.y - component.bbox.height,
                width: component.bbox.width,
                height: component.bbox.height
            )
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            path.stroke()
            let center = NSPoint(
                x: component.pixelCenter.x,
                y: CGFloat(image.height) - component.pixelCenter.y
            )
            NSBezierPath.strokeLine(from: NSPoint(x: center.x - 6, y: center.y), to: NSPoint(x: center.x + 6, y: center.y))
            NSBezierPath.strokeLine(from: NSPoint(x: center.x, y: center.y - 6), to: NSPoint(x: center.x, y: center.y + 6))
            let label = "r\(rowIndex)-c\(colIndex)" as NSString
            label.draw(at: NSPoint(x: rect.minX + 3, y: rect.maxY - 18), withAttributes: attrs)
        }
    }
    nsImage.unlockFocus()

    guard
        let tiff = nsImage.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        throw JsonError(description: "failed to render debug overlay PNG")
    }
    try png.write(to: URL(fileURLWithPath: path))
}

do {
    let startedAt = Date()
    let window = try findCalculatorWindow()
    let image = try captureWindow(window)
    let captureLatencyMs = Date().timeIntervalSince(startedAt) * 1000.0
    let buffer = try rgbaBuffer(from: image)
    let components = detectComponents(
        bytes: buffer.bytes,
        width: buffer.width,
        height: buffer.height,
        bytesPerRow: buffer.bytesPerRow
    )
    let rows = groupRows(components)
    try drawDebugOverlay(image: image, rows: rows, path: debugPath)

    let scaleX = window.bounds.width > 0 ? Double(buffer.width) / window.bounds.width : 1.0
    let scaleY = window.bounds.height > 0 ? Double(buffer.height) / window.bounds.height : 1.0
    var targets: [[String: Any]] = []
    for (rowIndex, row) in rows.enumerated() {
        for (colIndex, component) in row.enumerated() {
            let localX = component.pixelCenter.x / scaleX
            let localY = component.pixelCenter.y / scaleY
            targets.append([
                "target_id": "calculator-cell-r\(rowIndex)-c\(colIndex)",
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
    }

    try emit([
        "event": "calculator_readonly_map",
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
        "row_count": rows.count,
        "targets": targets,
        "debug_overlay": debugPath,
        "posted": false,
    ])
} catch {
    try emit([
        "event": "calculator_readonly_map",
        "status": "error",
        "error": "\(error)",
        "posted": false,
    ])
    exit(1)
}
