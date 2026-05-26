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

struct ProbeError: Error, CustomStringConvertible {
    let description: String
}

struct WindowInfo {
    let id: CGWindowID
    let owner: String
    let name: String
    let bounds: CGRect
}

struct FrameSample {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    let captureLatencyMs: Double
}

let ownerNeedles = (ProcessInfo.processInfo.environment["GENESIS_V64_WINDOW_OWNER"] ?? "Calculator,计算器")
    .split(separator: ",")
    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    .filter { !$0.isEmpty }
let sampleIntervalMs = parseEnvInt("GENESIS_V64_SAMPLE_INTERVAL_MS", defaultValue: 50, minValue: 10, maxValue: 1000)
let maxWaitMs = parseEnvInt("GENESIS_V64_MAX_WAIT_MS", defaultValue: 1500, minValue: 50, maxValue: 10000)
let stableFramesRequired = parseEnvInt("GENESIS_V64_STABLE_FRAMES", defaultValue: 3, minValue: 1, maxValue: 30)
let changedPixelThreshold = parseEnvDouble("GENESIS_V64_CHANGED_PIXEL_RATIO", defaultValue: 0.001, minValue: 0.0, maxValue: 1.0)
let byteDeltaThreshold = parseEnvInt("GENESIS_V64_BYTE_DELTA", defaultValue: 8, minValue: 0, maxValue: 255)

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
        throw ProbeError(description: "CGWindowListCopyWindowInfo returned no window list")
    }

    let windows = rawList.compactMap { info -> WindowInfo? in
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

    guard let window = windows.sorted(by: { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }).first else {
        throw ProbeError(description: "Calculator window not found; open Calculator before probing stability")
    }
    return window
}

func captureWindow(_ window: WindowInfo) throws -> FrameSample {
    let start = Date()
    guard let image = CGWindowListCreateImageLegacy(.null, 1 << 3, window.id, 1) else {
        throw ProbeError(description: "CGWindowListCreateImage returned null; Screen Recording permission may be required")
    }
    let captureLatencyMs = Date().timeIntervalSince(start) * 1000.0
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
        throw ProbeError(description: "failed to create RGBA bitmap context")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return FrameSample(bytes: bytes, width: width, height: height, captureLatencyMs: captureLatencyMs)
}

func changedPixelRatio(previous: FrameSample, current: FrameSample) -> Double {
    guard previous.width == current.width, previous.height == current.height else {
        return 1.0
    }
    let pixelCount = max(1, current.width * current.height)
    var changed = 0
    var offset = 0
    while offset + 3 < current.bytes.count && offset + 3 < previous.bytes.count {
        let dr = abs(Int(current.bytes[offset]) - Int(previous.bytes[offset]))
        let dg = abs(Int(current.bytes[offset + 1]) - Int(previous.bytes[offset + 1]))
        let db = abs(Int(current.bytes[offset + 2]) - Int(previous.bytes[offset + 2]))
        let da = abs(Int(current.bytes[offset + 3]) - Int(previous.bytes[offset + 3]))
        if max(max(dr, dg), max(db, da)) > byteDeltaThreshold {
            changed += 1
        }
        offset += 4
    }
    return Double(changed) / Double(pixelCount)
}

do {
    let window = try findCalculatorWindow()
    try emit([
        "event": "frame_stability_probe_start",
        "window_id": window.id,
        "window_owner": window.owner,
        "window_name": window.name,
        "window_bounds": [
            "x": window.bounds.origin.x,
            "y": window.bounds.origin.y,
            "width": window.bounds.width,
            "height": window.bounds.height,
        ],
        "sample_interval_ms": sampleIntervalMs,
        "max_wait_ms": maxWaitMs,
        "stable_frames_required": stableFramesRequired,
        "changed_pixel_ratio_threshold": changedPixelThreshold,
        "byte_delta_threshold": byteDeltaThreshold,
        "posted": false,
    ])

    let started = Date()
    var previous = try captureWindow(window)
    var sampleIndex = 0
    var stableRun = 0
    var finalStable = false
    var lastRatio = 1.0

    while true {
        Thread.sleep(forTimeInterval: Double(sampleIntervalMs) / 1000.0)
        let elapsedMs = Date().timeIntervalSince(started) * 1000.0
        let current = try captureWindow(window)
        let ratio = changedPixelRatio(previous: previous, current: current)
        lastRatio = ratio
        let stable = ratio <= changedPixelThreshold
        stableRun = stable ? stableRun + 1 : 0
        try emit([
            "event": "frame_stability_probe",
            "sample_index": sampleIndex,
            "elapsed_ms": elapsedMs,
            "capture_latency_ms": current.captureLatencyMs,
            "changed_pixel_ratio": ratio,
            "stable": stable,
            "stable_run": stableRun,
            "posted": false,
        ])
        if stableRun >= stableFramesRequired {
            finalStable = true
            break
        }
        if elapsedMs >= Double(maxWaitMs) {
            break
        }
        previous = current
        sampleIndex += 1
    }

    try emit([
        "event": "frame_stability_summary",
        "stable": finalStable,
        "stable_run": stableRun,
        "sample_count": sampleIndex + 1,
        "elapsed_ms": Date().timeIntervalSince(started) * 1000.0,
        "last_changed_pixel_ratio": lastRatio,
        "posted": false,
    ])
    if !finalStable {
        exit(2)
    }
} catch {
    try emit([
        "event": "frame_stability_probe_error",
        "error": "\(error)",
        "posted": false,
    ])
    exit(1)
}
