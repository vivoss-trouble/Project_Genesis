import AppKit
import ApplicationServices
import Foundation

let env = ProcessInfo.processInfo.environment
let bundleIdNeedle = env["GENESIS_V230_BROWSER_BUNDLE_ID"] ?? "com.apple.Safari"
let browserNameNeedle = (env["GENESIS_V230_BROWSER_APP"] ?? "Safari").lowercased()
let urlDomainLock = env["GENESIS_V230_URL_DOMAIN_LOCK"] ?? "wikipedia.org"
let targetText = env["GENESIS_V230_INTERNAL_LINK_TEXT"] ?? "微软"
let alternateText = env["GENESIS_V230_INTERNAL_LINK_ALT_TEXT"] ?? "Microsoft"
let maxDepth = Int(env["GENESIS_V230_AX_MAX_DEPTH"] ?? "18") ?? 18
let maxNodes = Int(env["GENESIS_V230_AX_MAX_NODES"] ?? "10000") ?? 10000

func emit(_ payload: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}

func jsonValue(_ value: Any?) -> Any {
    value ?? NSNull()
}

func copyAttribute(_ element: AXUIElement, _ attribute: String) -> (AXError, CFTypeRef?) {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return (status, value)
}

func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String {
    let (status, value) = copyAttribute(element, attribute)
    guard status == .success, let value else { return "" }
    if let string = value as? String { return string }
    if let url = value as? URL { return url.absoluteString }
    if let number = value as? NSNumber { return number.stringValue }
    if let bool = value as? Bool { return bool ? "true" : "false" }
    return ""
}

func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
    let (status, value) = copyAttribute(element, attribute)
    guard status == .success, let bool = value as? Bool else { return false }
    return bool
}

func children(of element: AXUIElement) -> [AXUIElement] {
    let (status, value) = copyAttribute(element, kAXChildrenAttribute)
    guard status == .success, let items = value as? [AXUIElement] else { return [] }
    return items
}

func windows(of appElement: AXUIElement) -> [AXUIElement] {
    let (status, value) = copyAttribute(appElement, kAXWindowsAttribute)
    guard status == .success, let items = value as? [AXUIElement] else { return [] }
    return items
}

func rectAttribute(_ element: AXUIElement, _ attribute: String) -> [String: Double]? {
    let (status, value) = copyAttribute(element, attribute)
    guard status == .success, let value else { return nil }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    var rect = CGRect.zero
    guard AXValueGetType(axValue) == .cgRect else { return nil }
    guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
    return [
        "x": Double(rect.origin.x),
        "y": Double(rect.origin.y),
        "width": Double(rect.size.width),
        "height": Double(rect.size.height),
        "center_x": Double(rect.midX),
        "center_y": Double(rect.midY),
        "area": Double(rect.size.width * rect.size.height),
    ]
}

func haystack(_ element: AXUIElement) -> String {
    [
        stringAttribute(element, kAXTitleAttribute),
        stringAttribute(element, kAXDescriptionAttribute),
        stringAttribute(element, kAXValueAttribute),
    ]
    .joined(separator: " ")
    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

func normalized(_ text: String) -> String {
    text.lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
}

func compact(_ text: String) -> String {
    text.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "", options: .regularExpression)
}

func visibleFrame(_ frame: [String: Double]?) -> Bool {
    guard let frame else { return false }
    return (frame["width"] ?? 0) > 2 && (frame["height"] ?? 0) > 2 && (frame["area"] ?? 0) > 8
}

func center(_ frame: [String: Double]?) -> [String: Double]? {
    guard let frame else { return nil }
    return ["x": frame["center_x"] ?? 0, "y": frame["center_y"] ?? 0]
}

func shouldDescend(role: String, depth: Int) -> Bool {
    guard depth < maxDepth else { return false }
    return [
        "AXWindow",
        "AXWebArea",
        "AXScrollArea",
        "AXGroup",
        "AXOpaqueProviderGroup",
        "AXSplitGroup",
        "AXTabGroup",
        "AXList",
        "AXTable",
        "AXRow",
        "AXColumn",
        "AXLink",
        "AXHeading",
        "AXStaticText",
        "AXTextField",
        "AXTextArea",
        "AXButton",
    ].contains(role)
}

struct QueueItem {
    let element: AXUIElement
    let depth: Int
    let path: [Int]
}

let trusted = AXIsProcessTrusted()
let app = NSWorkspace.shared.runningApplications.first { candidate in
    if let bundleIdentifier = candidate.bundleIdentifier,
       bundleIdentifier.lowercased() == bundleIdNeedle.lowercased() {
        return true
    }
    return (candidate.localizedName ?? "").lowercased().contains(browserNameNeedle)
}

guard let app else {
    emit([
        "event": "v230_wikipedia_internal_link_plan",
        "status": "error",
        "error": "browser app not running",
        "accessibility_api_trusted": trusted,
        "posted": false,
        "physical_input_posted": false,
        "os_driver_active": false,
    ])
    exit(1)
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)
let windowList = windows(of: appElement)
let selectedWindow = windowList.first { window in
    boolAttribute(window, kAXMainAttribute) || boolAttribute(window, kAXFocusedAttribute)
} ?? windowList.first

guard let selectedWindow else {
    emit([
        "event": "v230_wikipedia_internal_link_plan",
        "status": "error",
        "error": "browser window not found",
        "accessibility_api_trusted": trusted,
        "posted": false,
        "physical_input_posted": false,
        "os_driver_active": false,
    ])
    exit(1)
}

var visited = 0
var allItems: [QueueItem] = []
var queue = [QueueItem(element: selectedWindow, depth: 0, path: [])]

while !queue.isEmpty && visited < maxNodes {
    let item = queue.removeFirst()
    allItems.append(item)
    visited += 1
    let role = stringAttribute(item.element, kAXRoleAttribute)
    guard shouldDescend(role: role, depth: item.depth) else { continue }
    for (index, child) in children(of: item.element).enumerated() {
        queue.append(QueueItem(element: child, depth: item.depth + 1, path: item.path + [index]))
    }
}

let windowTitle = stringAttribute(selectedWindow, kAXTitleAttribute)
let windowFrame = rectAttribute(selectedWindow, "AXFrame")
let titleFrames = allItems.compactMap { item -> [String: Double]? in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    guard role == "AXHeading" || role == "AXStaticText" else { return nil }
    let text = haystack(item.element)
    guard compact(text).contains("openai") else { return nil }
    let frame = rectAttribute(item.element, "AXFrame")
    guard visibleFrame(frame) else { return nil }
    return frame
}.sorted { ($0["y"] ?? 0) < ($1["y"] ?? 0) }
let titleBottomY = titleFrames.first.map { ($0["y"] ?? 0) + ($0["height"] ?? 0) } ?? (windowFrame?["y"] ?? 0)
let windowMinY = windowFrame?["y"] ?? 0
let windowMaxY = (windowFrame?["y"] ?? 0) + (windowFrame?["height"] ?? 0)
let windowMinX = windowFrame?["x"] ?? 0
let windowMaxX = (windowFrame?["x"] ?? 0) + (windowFrame?["width"] ?? 0)

func frameIntersectsWindow(_ frame: [String: Double]?) -> Bool {
    guard let frame else { return false }
    let minY = frame["y"] ?? 0
    let maxY = minY + (frame["height"] ?? 0)
    let minX = frame["x"] ?? 0
    let maxX = minX + (frame["width"] ?? 0)
    return maxY >= windowMinY && minY <= windowMaxY && maxX >= windowMinX && minX <= windowMaxX
}

func urlFor(_ element: AXUIElement) -> String {
    for attr in ["AXURL", "AXLinkedUIElements"] {
        let value = stringAttribute(element, attr)
        if value.contains("http") { return value }
    }
    return ""
}

let targetCompacts = Set([compact(targetText), compact(alternateText)].filter { !$0.isEmpty })
let rawCandidates = allItems.compactMap { item -> [String: Any]? in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    guard role == "AXLink" else { return nil }
    let frame = rectAttribute(item.element, "AXFrame")
    guard visibleFrame(frame), frameIntersectsWindow(frame) else { return nil }
    let text = haystack(item.element)
    let compactText = compact(text)
    guard targetCompacts.contains(compactText) || targetCompacts.contains(where: { compactText.contains($0) }) else { return nil }
    let url = urlFor(item.element)
    let domainLocked = url.isEmpty || url.contains(urlDomainLock)
    return [
        "role": role,
        "text": text,
        "url": url,
        "domain_locked": domainLocked,
        "frame": jsonValue(frame),
        "point": jsonValue(center(frame)),
        "path": item.path,
        "window_y": frame?["center_y"] ?? 0,
        "after_title": (frame?["center_y"] ?? 0) > titleBottomY,
    ]
}

let domainSurvivors = rawCandidates.filter { ($0["domain_locked"] as? Bool) == true }
let mainContentSurvivors = domainSurvivors.filter { candidate in
    guard let frame = candidate["frame"] as? [String: Double] else { return false }
    let centerY = frame["center_y"] ?? 0
    let centerX = frame["center_x"] ?? 0
    let afterTitle = centerY > titleBottomY
    let insideMainColumn = centerX > windowMinX + 180 && centerX < windowMaxX - 120
    return afterTitle && insideMainColumn
}
let fallbackSurvivors = mainContentSurvivors.isEmpty
    ? domainSurvivors.filter { ($0["after_title"] as? Bool) == true }
    : mainContentSurvivors
let sortedSurvivors = fallbackSurvivors.sorted {
    (($0["window_y"] as? Double) ?? 0) < (($1["window_y"] as? Double) ?? 0)
}
let selected = sortedSurvivors.first
let planReady = selected != nil

emit([
    "event": "v230_wikipedia_internal_link_plan",
    "status": "ok",
    "profile": "v23.0-wikipedia-multi-hop",
    "accessibility_api_trusted": trusted,
    "browser_bundle_id": app.bundleIdentifier ?? "",
    "browser_localized_name": app.localizedName ?? "",
    "browser_pid": app.processIdentifier,
    "selected_window_title": windowTitle,
    "window_frame": jsonValue(windowFrame),
    "target_text": targetText,
    "alternate_text": alternateText,
    "url_domain_lock": urlDomainLock,
    "candidate_count": rawCandidates.count,
    "survivor_count": sortedSurvivors.count,
    "domain_survivor_count": domainSurvivors.count,
    "main_content_survivor_count": mainContentSurvivors.count,
    "tie_breaker": "main_content_first_y",
    "internal_link_plan_ready": planReady,
    "selected_candidate": selected ?? [:],
    "selected_point": jsonValue(selected?["point"]),
    "candidates": Array(rawCandidates.prefix(16)),
    "survivors": Array(sortedSurvivors.prefix(8)),
    "title_bottom_y": titleBottomY,
    "visited_count": visited,
    "posted": false,
    "physical_input_posted": false,
    "os_driver_active": false,
])
