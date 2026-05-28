import AppKit
import ApplicationServices
import Foundation

let env = ProcessInfo.processInfo.environment
let bundleIdNeedle = env["GENESIS_V220_BROWSER_BUNDLE_ID"] ?? "com.apple.Safari"
let browserNameNeedle = (env["GENESIS_V220_BROWSER_APP"] ?? "Safari").lowercased()
let query = env["GENESIS_V220_SEARCH_QUERY"] ?? "OpenAI"
let urlDomainLock = env["GENESIS_V220_URL_DOMAIN_LOCK"] ?? "wikipedia.org"
let maxDepth = Int(env["GENESIS_V220_AX_MAX_DEPTH"] ?? "16") ?? 16
let maxNodes = Int(env["GENESIS_V220_AX_MAX_NODES"] ?? "8000") ?? 8000

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
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

func visibleFrame(_ frame: [String: Double]?) -> Bool {
    guard let frame else { return false }
    return (frame["width"] ?? 0) > 2 && (frame["height"] ?? 0) > 2 && (frame["area"] ?? 0) > 8
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

func textSample(_ text: String, maxCount: Int = 360) -> String {
    let normalized = text
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.count <= maxCount { return normalized }
    return String(normalized.prefix(maxCount))
}

func normalized(_ text: String) -> String {
    text.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
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
        "event": "v220_wikipedia_result_extraction",
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
        "event": "v220_wikipedia_result_extraction",
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
let queryNeedle = normalized(query)

func frameIntersectsWindow(_ frame: [String: Double]?) -> Bool {
    guard let frame, let windowFrame else { return true }
    let minY = frame["y"] ?? 0
    let maxY = minY + (frame["height"] ?? 0)
    let windowMinY = windowFrame["y"] ?? 0
    let windowMaxY = windowMinY + (windowFrame["height"] ?? 0)
    return maxY >= windowMinY && minY <= windowMaxY
}

let headingCandidates = allItems.compactMap { item -> [String: Any]? in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    guard role == "AXHeading" || role == "AXStaticText" else { return nil }
    let frame = rectAttribute(item.element, "AXFrame")
    guard visibleFrame(frame) else { return nil }
    let text = textSample(haystack(item.element), maxCount: 120)
    guard !text.isEmpty else { return nil }
    let norm = normalized(text)
    let containsQuery = !queryNeedle.isEmpty && norm.contains(queryNeedle)
    let lengthPenalty = abs(text.count - query.count)
    let y = frame?["y"] ?? 9_999_999
    let score = (containsQuery ? 10_000.0 : 0.0) - Double(lengthPenalty * 10) - (y / 100.0)
    return [
        "role": role,
        "text": text,
        "frame": jsonValue(frame),
        "contains_query": containsQuery,
        "score": score,
        "path": item.path,
    ]
}.sorted {
    (($0["score"] as? Double) ?? 0) > (($1["score"] as? Double) ?? 0)
}

let selectedHeading = headingCandidates.first
let selectedHeadingText = selectedHeading?["text"] as? String ?? {
    if windowTitle.lowercased().contains(query.lowercased()) {
        return windowTitle.components(separatedBy: " - ").first ?? windowTitle
    }
    return ""
}()
let titleAsserted = !selectedHeadingText.isEmpty && normalized(selectedHeadingText).contains(queryNeedle)

let bodyCandidates = allItems.compactMap { item -> [String: Any]? in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    guard ["AXStaticText", "AXGroup", "AXTextArea"].contains(role) else { return nil }
    let frame = rectAttribute(item.element, "AXFrame")
    guard visibleFrame(frame), frameIntersectsWindow(frame) else { return nil }
    let text = textSample(haystack(item.element), maxCount: 700)
    let compactLength = text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression).count
    guard compactLength >= 40 else { return nil }
    let area = frame?["area"] ?? 0
    let width = frame?["width"] ?? 0
    let y = frame?["y"] ?? 0
    let textMass = Double(compactLength)
    let containsQuery = normalized(text).contains(queryNeedle)
    let roleBoost = role == "AXStaticText" ? 200.0 : 0.0
    let score = textMass * 10.0 + min(area / 80.0, 800.0) + min(width / 2.0, 500.0) + roleBoost + (containsQuery ? 600.0 : 0.0) - min(y / 10.0, 250.0)
    return [
        "role": role,
        "text_sample": text,
        "text_length": compactLength,
        "contains_query": containsQuery,
        "frame": jsonValue(frame),
        "score": score,
        "path": item.path,
    ]
}.sorted {
    (($0["score"] as? Double) ?? 0) > (($1["score"] as? Double) ?? 0)
}

let selectedLead = bodyCandidates.first
let leadTextLength = selectedLead?["text_length"] as? Int ?? 0
let leadFound = leadTextLength >= 40

let tocCandidates = allItems.compactMap { item -> [String: Any]? in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    guard ["AXList", "AXGroup", "AXStaticText"].contains(role) else { return nil }
    let frame = rectAttribute(item.element, "AXFrame")
    guard visibleFrame(frame) else { return nil }
    let text = textSample(haystack(item.element), maxCount: 240)
    let lower = text.lowercased()
    guard lower.contains("contents") || lower.contains("目录") || lower.contains("參考") else { return nil }
    return [
        "role": role,
        "text_sample": text,
        "frame": jsonValue(frame),
        "path": item.path,
    ]
}

let extractionAsserted = titleAsserted && leadFound

emit([
    "event": "v220_wikipedia_result_extraction",
    "status": "ok",
    "profile": "v22.0-wikipedia-result-extraction",
    "accessibility_api_trusted": trusted,
    "browser_bundle_id": app.bundleIdentifier ?? "",
    "browser_localized_name": app.localizedName ?? "",
    "browser_pid": app.processIdentifier,
    "url_domain_lock": urlDomainLock,
    "query": query,
    "selected_window_title": windowTitle,
    "window_frame": jsonValue(windowFrame),
    "result_title_found": titleAsserted,
    "result_title": selectedHeadingText,
    "heading_candidates": Array(headingCandidates.prefix(8)),
    "lead_text_found": leadFound,
    "lead_text_sample": selectedLead?["text_sample"] ?? "",
    "lead_text_length": leadTextLength,
    "lead_candidates": Array(bodyCandidates.prefix(8)),
    "toc_found": !tocCandidates.isEmpty,
    "toc_candidates": Array(tocCandidates.prefix(4)),
    "extraction_asserted": extractionAsserted,
    "visited_count": visited,
    "posted": false,
    "physical_input_posted": false,
    "os_driver_active": false,
])
