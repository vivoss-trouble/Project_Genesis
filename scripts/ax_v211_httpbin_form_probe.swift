import AppKit
import ApplicationServices
import Foundation

let env = ProcessInfo.processInfo.environment
let bundleIdNeedle = env["GENESIS_V211_BROWSER_BUNDLE_ID"] ?? "com.apple.Safari"
let browserNameNeedle = (env["GENESIS_V211_BROWSER_APP"] ?? "Safari").lowercased()
let titleNeedle = (env["GENESIS_V211_WINDOW_TITLE"] ?? "httpbin.org").lowercased()
let fieldNeedle = (env["GENESIS_V211_FIELD_LABEL"] ?? "Customer name").lowercased()
let commitNeedle = (env["GENESIS_V211_COMMIT_TITLE"] ?? "Submit order").lowercased()
let expectedValue = env["GENESIS_V211_EXPECT_VALUE"] ?? "Genesis"
let mutateRequested = env["GENESIS_V211_SET_FIELD"] == "1"
let mutateAuthorized = env["GENESIS_V211_MUTATE_CONFIRM"] == "GENESIS_V211_MUTATE_HTTPBIN_FORM_STATE"
let maxDepth = Int(env["GENESIS_V211_AX_MAX_DEPTH"] ?? "16") ?? 16
let maxNodes = Int(env["GENESIS_V211_AX_MAX_NODES"] ?? "5000") ?? 5000

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

func actionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    let status = AXUIElementCopyActionNames(element, &names)
    guard status == .success, let strings = names as? [String] else { return [] }
    return strings.sorted()
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

func center(_ frame: [String: Double]?) -> [String: Double]? {
    guard let frame else { return nil }
    return ["x": frame["center_x"] ?? 0, "y": frame["center_y"] ?? 0]
}

func visibleFrame(_ frame: [String: Double]?) -> Bool {
    guard let frame else { return false }
    return (frame["width"] ?? 0) > 1 && (frame["height"] ?? 0) > 1 && (frame["area"] ?? 0) > 4
}

func haystack(_ element: AXUIElement) -> String {
    [
        stringAttribute(element, kAXTitleAttribute),
        stringAttribute(element, kAXDescriptionAttribute),
        stringAttribute(element, kAXValueAttribute),
        stringAttribute(element, "AXDOMIdentifier"),
        stringAttribute(element, "AXDOMClassList"),
    ].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

func statusName(_ status: AXError) -> String {
    switch status {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegal_argument"
    case .invalidUIElement: return "invalid_ui_element"
    case .invalidUIElementObserver: return "invalid_ui_element_observer"
    case .cannotComplete: return "cannot_complete"
    case .attributeUnsupported: return "attribute_unsupported"
    case .actionUnsupported: return "action_unsupported"
    case .notificationUnsupported: return "notification_unsupported"
    case .notImplemented: return "not_implemented"
    case .notificationAlreadyRegistered: return "notification_already_registered"
    case .notificationNotRegistered: return "notification_not_registered"
    case .apiDisabled: return "api_disabled"
    case .noValue: return "no_value"
    case .parameterizedAttributeUnsupported: return "parameterized_attribute_unsupported"
    case .notEnoughPrecision: return "not_enough_precision"
    @unknown default: return "unknown_\(status.rawValue)"
    }
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
        "AXButton",
        "AXHeading",
        "AXStaticText",
        "AXTextField",
        "AXTextArea",
    ].contains(role)
}

func payload(_ element: AXUIElement, depth: Int, path: [Int]) -> [String: Any] {
    [
        "role": stringAttribute(element, kAXRoleAttribute),
        "subrole": stringAttribute(element, kAXSubroleAttribute),
        "title": stringAttribute(element, kAXTitleAttribute),
        "description": stringAttribute(element, kAXDescriptionAttribute),
        "value": stringAttribute(element, kAXValueAttribute),
        "frame": jsonValue(rectAttribute(element, "AXFrame")),
        "global_coregraphics_point": jsonValue(center(rectAttribute(element, "AXFrame"))),
        "actions": actionNames(element),
        "depth": depth,
        "path": path,
        "child_count": children(of: element).count,
    ]
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
        "event": "v211_httpbin_form_probe",
        "status": "error",
        "error": "browser app not running",
        "accessibility_api_trusted": trusted,
        "posted": false,
        "physical_input_posted": false,
    ])
    exit(1)
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)
let windowList = windows(of: appElement)
let matchingWindows = windowList.filter { window in
    stringAttribute(window, kAXTitleAttribute).lowercased().contains(titleNeedle)
}
let selectedWindow = matchingWindows.first { window in
    boolAttribute(window, kAXMainAttribute) || boolAttribute(window, kAXFocusedAttribute)
} ?? matchingWindows.first ?? windowList.first { window in
    boolAttribute(window, kAXMainAttribute) || boolAttribute(window, kAXFocusedAttribute)
}

guard let selectedWindow else {
    emit([
        "event": "v211_httpbin_form_probe",
        "status": "error",
        "error": "matching browser window not found",
        "requested_window_title": titleNeedle,
        "window_titles": windowList.map { stringAttribute($0, kAXTitleAttribute) },
        "accessibility_api_trusted": trusted,
        "posted": false,
        "physical_input_posted": false,
    ])
    exit(1)
}

var visited = 0
var queue = [QueueItem(element: selectedWindow, depth: 0, path: [])]
var allItems: [QueueItem] = []

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

func inferredLabel(for field: QueueItem) -> String {
    let direct = haystack(field.element)
    if !direct.isEmpty { return direct }
    guard let fieldFrame = rectAttribute(field.element, "AXFrame"),
          let fieldX = fieldFrame["x"],
          let fieldCenterY = fieldFrame["center_y"] else {
        return ""
    }
    let candidates = allItems.compactMap { item -> (String, Double)? in
        let role = stringAttribute(item.element, kAXRoleAttribute)
        guard role == "AXStaticText" || role == "AXHeading" else { return nil }
        guard let frame = rectAttribute(item.element, "AXFrame"),
              let centerY = frame["center_y"],
              let x = frame["x"],
              let width = frame["width"] else { return nil }
        let rightEdge = x + width
        guard abs(centerY - fieldCenterY) <= 36 else { return nil }
        guard rightEdge <= fieldX + 8 else { return nil }
        let text = haystack(item.element)
        guard !text.isEmpty else { return nil }
        return (text, abs(fieldX - rightEdge) + abs(centerY - fieldCenterY))
    }
    return candidates.sorted { $0.1 < $1.1 }.first?.0 ?? ""
}

let textFields = allItems.filter { item in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    return (role == "AXTextField" || role == "AXTextArea")
        && visibleFrame(rectAttribute(item.element, "AXFrame"))
}
let fieldCandidates = textFields.map { item -> (QueueItem, String) in
    (item, inferredLabel(for: item))
}
let selectedField = fieldCandidates.first { _, label in
    label.lowercased().contains(fieldNeedle)
} ?? fieldCandidates.first

let commitCandidates = allItems.filter { item in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    let label = haystack(item.element).lowercased()
    return visibleFrame(rectAttribute(item.element, "AXFrame"))
        && (role == "AXButton" || actionNames(item.element).contains("AXPress"))
        && label.contains(commitNeedle)
}
let selectedCommit = commitCandidates.first

let responseMatches = allItems.filter { item in
    haystack(item.element).contains(expectedValue)
}
let custnameMatches = allItems.filter { item in
    haystack(item.element).lowercased().contains("custname")
}
let responseStateAsserted = !responseMatches.isEmpty && !custnameMatches.isEmpty

var mutationStatus: [String: Any] = [
    "ax_mutation_attempted": false,
    "ax_mutation_authorized": mutateAuthorized,
    "ax_mutation_status": "not_requested",
]

var fieldValueAfterSet: String? = selectedField.map { stringAttribute($0.0.element, kAXValueAttribute) }
if mutateRequested {
    mutationStatus["ax_mutation_attempted"] = true
    if mutateAuthorized, let selectedField {
        _ = AXUIElementSetAttributeValue(
            selectedField.0.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        let status = AXUIElementSetAttributeValue(
            selectedField.0.element,
            kAXValueAttribute as CFString,
            expectedValue as CFTypeRef
        )
        fieldValueAfterSet = stringAttribute(selectedField.0.element, kAXValueAttribute)
        mutationStatus["ax_mutation_status"] = statusName(status)
        mutationStatus["input_set_success"] = status == .success && fieldValueAfterSet == expectedValue
    } else {
        mutationStatus["ax_mutation_status"] = "unauthorized_or_field_missing"
        mutationStatus["input_set_success"] = false
    }
}

let fieldPayload: Any
if let selectedField {
    var item = payload(selectedField.0.element, depth: selectedField.0.depth, path: selectedField.0.path)
    item["inferred_label"] = selectedField.1
    fieldPayload = item
} else {
    fieldPayload = NSNull()
}

let commitPayload: Any
if let selectedCommit {
    commitPayload = payload(selectedCommit.element, depth: selectedCommit.depth, path: selectedCommit.path)
} else {
    commitPayload = NSNull()
}

var output: [String: Any] = [
    "event": "v211_httpbin_form_probe",
    "status": "ok",
    "accessibility_api_trusted": trusted,
    "selected_window_title": stringAttribute(selectedWindow, kAXTitleAttribute),
    "visited_count": visited,
    "target_kind": "httpbin_standard_form",
    "field_found": selectedField != nil,
    "field_candidate_count": fieldCandidates.count,
    "field_label": selectedField?.1 ?? "",
    "field_value": selectedField.map { stringAttribute($0.0.element, kAXValueAttribute) } ?? "",
    "field_value_after_set": fieldValueAfterSet ?? "",
    "field_point": jsonValue(selectedField.flatMap { center(rectAttribute($0.0.element, "AXFrame")) }),
    "field_payload": fieldPayload,
    "commit_found": selectedCommit != nil,
    "commit_candidate_count": commitCandidates.count,
    "commit_point": jsonValue(selectedCommit.flatMap { center(rectAttribute($0.element, "AXFrame")) }),
    "commit_payload": commitPayload,
    "response_state_asserted": responseStateAsserted,
    "response_match_count": responseMatches.count,
    "custname_match_count": custnameMatches.count,
    "expected_value": expectedValue,
    "posted": false,
    "physical_input_posted": false,
]
for (key, value) in mutationStatus {
    output[key] = value
}

emit(output)
