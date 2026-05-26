import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@_silgen_name("CGWindowListCreateImage")
func CGWindowListCreateImageLegacy(
    _ screenBounds: CGRect,
    _ listOption: UInt32,
    _ windowID: CGWindowID,
    _ imageOption: UInt32
) -> CGImage?

struct HashError: Error, CustomStringConvertible {
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

let ownerNeedles = (ProcessInfo.processInfo.environment["GENESIS_V66_WINDOW_OWNER"] ?? "Calculator,计算器")
    .split(separator: ",")
    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    .filter { !$0.isEmpty }
let cropPath = ProcessInfo.processInfo.environment["GENESIS_V66_DISPLAY_CROP_PNG"]
    ?? "/tmp/genesis_v66_display_crop.png"
let debugPath = ProcessInfo.processInfo.environment["GENESIS_V66_DEBUG_PNG"]
    ?? "/tmp/genesis_v66_display_debug.png"
let baselineJsonPath = ProcessInfo.processInfo.environment["GENESIS_V66_BASELINE_JSON"]
let changedPixelThreshold = parseEnvDouble("GENESIS_V66_CHANGED_PIXEL_RATIO", defaultValue: 0.01, minValue: 0.0, maxValue: 1.0)
let hashDistanceThreshold = parseEnvInt("GENESIS_V66_HASH_DISTANCE", defaultValue: 0, minValue: 0, maxValue: 64)
let byteDeltaThreshold = parseEnvInt("GENESIS_V66_BYTE_DELTA", defaultValue: 8, minValue: 0, maxValue: 255)

func parseEnvInt(_ key: String, defaultValue: Int, minValue: Int, maxValue: Int) -> Int {
    guard
        let raw = ProcessInfo.processInfo.environment[key],
        let value = Int(raw),
        value >= minValue,
        value <= maxValue
    else {
        return defaultValue
    }
    return value
}

func parseEnvDouble(_ key: String, defaultValue: Double, minValue: Double, maxValue: Double) -> Double {
    guard
        let raw = ProcessInfo.processInfo.environment[key],
        let value = Double(raw),
        value.isFinite,
        value >= minValue,
        value <= maxValue
    else {
        return defaultValue
    }
    return value
}

func emit(_ payload: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}

func findCalculatorWindow() throws -> WindowInfo {
    guard let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else {
        throw HashError(description: "CGWindowListCopyWindowInfo returned no window list")
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
        throw HashError(description: "Calculator window not found; open Calculator before v6.6 display hashing")
    }
    return window
}

func captureWindow(_ window: WindowInfo) throws -> CGImage {
    guard let image = CGWindowListCreateImageLegacy(.null, 1 << 3, window.id, 1) else {
        throw HashError(description: "CGWindowListCreateImage returned null for Calculator window; Screen Recording permission may be required")
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
        throw HashError(description: "failed to create RGBA bitmap context")
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

                for (nx, ny) in [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)] {
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

func displayRect(components: [Component], width: Int, height: Int) throws -> CGRect {
    guard let topButtonY = components.map({ $0.bbox.origin.y }).min() else {
        throw HashError(description: "button grid not found; cannot derive display bbox")
    }
    let marginX = max(12, Int(Double(width) * 0.045))
    let topMargin = max(20, Int(Double(height) * 0.055))
    let bottomPadding = max(12, Int(Double(height) * 0.035))
    let y = topMargin
    let h = max(24, Int(topButtonY) - topMargin - bottomPadding)
    return CGRect(x: marginX, y: y, width: width - marginX * 2, height: h)
}

func croppedBytes(buffer: (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int), rect: CGRect) -> [UInt8] {
    let x0 = max(0, Int(rect.origin.x))
    let y0 = max(0, Int(rect.origin.y))
    let w = min(Int(rect.width), buffer.width - x0)
    let h = min(Int(rect.height), buffer.height - y0)
    var output = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        let src = (y0 + y) * buffer.bytesPerRow + x0 * 4
        let dst = y * w * 4
        output[dst..<(dst + w * 4)] = buffer.bytes[src..<(src + w * 4)]
    }
    return output
}

func writePng(bytes: [UInt8], width: Int, height: Int, path: String) throws {
    var mutable = bytes
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    guard
        let context = CGContext(
            data: &mutable,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ),
        let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        throw HashError(description: "failed to create crop PNG")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw HashError(description: "failed to write crop PNG")
    }
}

func fnv1a64(_ bytes: [UInt8]) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in bytes {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3
    }
    return String(format: "%016llx", hash)
}

func averageHash(_ bytes: [UInt8], width: Int, height: Int) -> String {
    let grid = 8
    var cells = [Double](repeating: 0.0, count: grid * grid)
    for gy in 0..<grid {
        let yStart = gy * height / grid
        let yEnd = max(yStart + 1, (gy + 1) * height / grid)
        for gx in 0..<grid {
            let xStart = gx * width / grid
            let xEnd = max(xStart + 1, (gx + 1) * width / grid)
            var sum = 0.0
            var count = 0
            for y in yStart..<min(yEnd, height) {
                for x in xStart..<min(xEnd, width) {
                    let offset = (y * width + x) * 4
                    let r = Double(bytes[offset])
                    let g = Double(bytes[offset + 1])
                    let b = Double(bytes[offset + 2])
                    sum += 0.299 * r + 0.587 * g + 0.114 * b
                    count += 1
                }
            }
            cells[gy * grid + gx] = count > 0 ? sum / Double(count) : 0.0
        }
    }
    let mean = cells.reduce(0.0, +) / Double(cells.count)
    var value: UInt64 = 0
    for (index, cell) in cells.enumerated() {
        if cell >= mean {
            value |= UInt64(1) << UInt64(63 - index)
        }
    }
    return String(format: "%016llx", value)
}

func hammingHex(_ lhs: String, _ rhs: String) -> Int {
    guard let a = UInt64(lhs, radix: 16), let b = UInt64(rhs, radix: 16) else {
        return 64
    }
    return (a ^ b).nonzeroBitCount
}

func changedRatio(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
    guard lhs.count == rhs.count, !lhs.isEmpty else {
        return 1.0
    }
    let pixels = lhs.count / 4
    var changed = 0
    var offset = 0
    while offset + 3 < lhs.count {
        let dr = abs(Int(lhs[offset]) - Int(rhs[offset]))
        let dg = abs(Int(lhs[offset + 1]) - Int(rhs[offset + 1]))
        let db = abs(Int(lhs[offset + 2]) - Int(rhs[offset + 2]))
        let da = abs(Int(lhs[offset + 3]) - Int(rhs[offset + 3]))
        if max(max(dr, dg), max(db, da)) > byteDeltaThreshold {
            changed += 1
        }
        offset += 4
    }
    return Double(changed) / Double(max(1, pixels))
}

func meanRgb(_ bytes: [UInt8]) -> [String: Double] {
    let pixels = max(1, bytes.count / 4)
    var r = 0.0
    var g = 0.0
    var b = 0.0
    var offset = 0
    while offset + 2 < bytes.count {
        r += Double(bytes[offset])
        g += Double(bytes[offset + 1])
        b += Double(bytes[offset + 2])
        offset += 4
    }
    return [
        "r": r / Double(pixels),
        "g": g / Double(pixels),
        "b": b / Double(pixels),
    ]
}

func drawDebugOverlay(image: CGImage, display: CGRect, path: String) throws {
    let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    nsImage.lockFocus()
    NSColor.systemBlue.setStroke()
    NSColor.systemBlue.setFill()
    let rect = NSRect(
        x: display.origin.x,
        y: CGFloat(image.height) - display.origin.y - display.height,
        width: display.width,
        height: display.height
    )
    let pathShape = NSBezierPath(rect: rect)
    pathShape.lineWidth = 3
    pathShape.stroke()
    let label = "calculator-display-screen" as NSString
    label.draw(
        at: NSPoint(x: rect.minX + 4, y: rect.maxY - 20),
        withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.systemBlue,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7),
        ]
    )
    nsImage.unlockFocus()
    guard
        let tiff = nsImage.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        throw HashError(description: "failed to render display debug overlay PNG")
    }
    try png.write(to: URL(fileURLWithPath: path))
}

func baselineBytes(from path: String) throws -> (bytes: [UInt8], width: Int, height: Int, exactHash: String, averageHash: String) {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let crop = payload["crop_png"] as? String,
        let exactHash = payload["exact_hash"] as? String,
        let avgHash = payload["average_hash"] as? String,
        let image = NSImage(contentsOfFile: crop),
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else {
        throw HashError(description: "baseline JSON is missing crop_png or hashes: \(path)")
    }
    let buffer = try rgbaBuffer(from: cgImage)
    return (buffer.bytes, buffer.width, buffer.height, exactHash, avgHash)
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
    let display = try displayRect(components: components, width: buffer.width, height: buffer.height)
    let cropWidth = Int(display.width)
    let cropHeight = Int(display.height)
    let cropBytes = croppedBytes(buffer: buffer, rect: display)
    try writePng(bytes: cropBytes, width: cropWidth, height: cropHeight, path: cropPath)
    try drawDebugOverlay(image: image, display: display, path: debugPath)

    let scaleX = window.bounds.width > 0 ? Double(buffer.width) / window.bounds.width : 1.0
    let scaleY = window.bounds.height > 0 ? Double(buffer.height) / window.bounds.height : 1.0
    let localRect = [
        "x": display.origin.x / scaleX,
        "y": display.origin.y / scaleY,
        "width": display.width / scaleX,
        "height": display.height / scaleY,
    ]
    let globalRect = [
        "x": window.bounds.origin.x + display.origin.x / scaleX,
        "y": window.bounds.origin.y + display.origin.y / scaleY,
        "width": display.width / scaleX,
        "height": display.height / scaleY,
    ]
    let exactHash = fnv1a64(cropBytes)
    let avgHash = averageHash(cropBytes, width: cropWidth, height: cropHeight)
    var payload: [String: Any] = [
        "event": "calculator_display_hash",
        "target_id": "calculator-display-screen",
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
        "display_bbox": [
            "x": display.origin.x,
            "y": display.origin.y,
            "width": display.width,
            "height": display.height,
        ],
        "display_window_coregraphics_rect": localRect,
        "display_global_coregraphics_rect": globalRect,
        "crop_png": cropPath,
        "debug_overlay": debugPath,
        "crop_width": cropWidth,
        "crop_height": cropHeight,
        "mean_rgb": meanRgb(cropBytes),
        "exact_hash": exactHash,
        "average_hash": avgHash,
        "capture_latency_ms": captureLatencyMs,
        "button_component_count": components.count,
        "posted": false,
    ]

    if let baselineJsonPath {
        let baseline = try baselineBytes(from: baselineJsonPath)
        let ratio = baseline.width == cropWidth && baseline.height == cropHeight
            ? changedRatio(baseline.bytes, cropBytes)
            : 1.0
        let distance = hammingHex(baseline.averageHash, avgHash)
        payload["baseline_json"] = baselineJsonPath
        payload["baseline_exact_hash"] = baseline.exactHash
        payload["baseline_average_hash"] = baseline.averageHash
        payload["changed_pixel_ratio"] = ratio
        payload["hash_distance"] = distance
        payload["match"] = ratio <= changedPixelThreshold && distance <= hashDistanceThreshold
        payload["changed_pixel_ratio_threshold"] = changedPixelThreshold
        payload["hash_distance_threshold"] = hashDistanceThreshold
        payload["byte_delta_threshold"] = byteDeltaThreshold
    }

    try emit(payload)
} catch {
    try emit([
        "event": "calculator_display_hash",
        "status": "error",
        "error": "\(error)",
        "posted": false,
    ])
    exit(1)
}
