import AppKit
import ApplicationServices
import Foundation

let env = ProcessInfo.processInfo.environment
let bundleIdNeedle = env["GENESIS_V170A_BROWSER_BUNDLE_ID"] ?? "com.apple.Safari"
let browserNameNeedle = (env["GENESIS_V170A_BROWSER_APP"] ?? "Safari").lowercased()
let titleNeedle = (env["GENESIS_V170A_WINDOW_TITLE"] ?? "Checkbox Example").lowercased()
let targetLabelNeedle = (env["GENESIS_V170A_TARGET_LABEL"] ?? "Lettuce").lowercased()
let targetKindNeedle = (env["GENESIS_V170A_TARGET_KIND"] ?? "checkbox_or_radio").lowercased()
let scrollToVisibleRequested = env["GENESIS_V170A_SCROLL_TO_VISIBLE"] == "1"
let scrollToVisibleAuthorized = env["GENESIS_V170A_SCROLL_TO_VISIBLE_CONFIRM"] == "GENESIS_V170A_SCROLL_TO_VISIBLE_PUBLIC_BINARY"
let maxDepth = Int(env["GENESIS_V170A_AX_MAX_DEPTH"] ?? "14") ?? 14
let maxNodes = Int(env["GENESIS_V170A_AX_MAX_NODES"] ?? "4200") ?? 4200

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
    guard status == .success, let value else { return false }
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? String {
        let lowered = string.lowercased()
        return ["true", "1", "yes", "checked", "selected"].contains(lowered)
    }
    return false
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

func attributeNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    let status = AXUIElementCopyAttributeNames(element, &names)
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

func haystack(_ element: AXUIElement) -> String {
    [
        stringAttribute(element, kAXTitleAttribute),
        stringAttribute(element, kAXDescriptionAttribute),
        stringAttribute(element, kAXValueAttribute),
        stringAttribute(element, "AXDOMIdentifier"),
    ].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

func center(_ frame: [String: Double]?) -> [String: Double]? {
    guard let frame else { return nil }
    return ["x": frame["center_x"] ?? 0, "y": frame["center_y"] ?? 0]
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
        "AXWebArea",
        "AXWindow",
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
        "AXCheckBox",
        "AXRadioButton",
    ].contains(role)
}

func parseDiscreteState(_ raw: String) -> Bool? {
    let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if ["true", "1", "yes", "checked", "selected", "on"].contains(lowered) { return true }
    if ["false", "0", "no", "unchecked", "unselected", "off"].contains(lowered) { return false }
    return nil
}

func discreteState(_ element: AXUIElement) -> (Bool?, String, [String: Any]) {
    let stateAttributes = [
        "AXChecked",
        kAXValueAttribute,
        "AXSelected",
        "AXARIAChecked",
        "AXAriaChecked",
    ]
    var raw: [String: Any] = [:]
    for attribute in stateAttributes {
        let (status, value) = copyAttribute(element, attribute)
        guard status == .success, let value else {
            raw[attribute] = ["status": statusName(status)]
            continue
        }
        if let bool = value as? Bool {
            raw[attribute] = bool
            return (bool, attribute, raw)
        }
        if let number = value as? NSNumber {
            raw[attribute] = number
            return (number.boolValue, attribute, raw)
        }
        if let string = value as? String {
            raw[attribute] = string
            if let parsed = parseDiscreteState(string) {
                return (parsed, attribute, raw)
            }
        } else {
            raw[attribute] = "\(value)"
        }
    }
    return (nil, "none", raw)
}

func elementPayload(_ element: AXUIElement, depth: Int, path: [Int]) -> [String: Any] {
    let (state, stateSource, rawState) = discreteState(element)
    return [
        "depth": depth,
        "path": path,
        "role": stringAttribute(element, kAXRoleAttribute),
        "subrole": stringAttribute(element, kAXSubroleAttribute),
        "title": stringAttribute(element, kAXTitleAttribute),
        "description": stringAttribute(element, kAXDescriptionAttribute),
        "value": stringAttribute(element, kAXValueAttribute),
        "frame": jsonValue(rectAttribute(element, "AXFrame")),
        "actions": actionNames(element),
        "attribute_names": attributeNames(element),
        "child_count": children(of: element).count,
        "state": jsonValue(state),
        "state_source": stateSource,
        "raw_state": rawState,
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
        "event": "v170a_public_binary_state_probe",
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
} ?? matchingWindows.first

guard let selectedWindow else {
    emit([
        "event": "v170a_public_binary_state_probe",
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

func kindMatches(role: String) -> Bool {
    let lowered = role.lowercased()
    if targetKindNeedle.contains("checkbox") && lowered.contains("checkbox") { return true }
    if targetKindNeedle.contains("radio") && lowered.contains("radio") { return true }
    if targetKindNeedle == "checkbox_or_radio" {
        return lowered.contains("checkbox") || lowered.contains("radio")
    }
    return lowered.contains(targetKindNeedle)
}

let candidates = allItems.filter { item in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    let label = haystack(item.element).lowercased()
    let actions = actionNames(item.element)
    let frame = rectAttribute(item.element, "AXFrame")
    let area = frame?["area"] ?? 0
    return kindMatches(role: role)
        && label.contains(targetLabelNeedle)
        && area > 0
        && actions.contains("AXPress")
}

let selected = candidates.min { lhs, rhs in
    let lhsArea = rectAttribute(lhs.element, "AXFrame")?["area"] ?? Double.greatestFiniteMagnitude
    let rhsArea = rectAttribute(rhs.element, "AXFrame")?["area"] ?? Double.greatestFiniteMagnitude
    return lhsArea < rhsArea
}

var scrollToVisibleStatus = "not_requested"
if scrollToVisibleRequested {
    if scrollToVisibleAuthorized, let selected {
        let status = AXUIElementPerformAction(selected.element, "AXScrollToVisible" as CFString)
        scrollToVisibleStatus = statusName(status)
        usleep(150_000)
    } else {
        scrollToVisibleStatus = scrollToVisibleAuthorized ? "target_missing" : "not_authorized"
    }
}

let selectedPayload = selected.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:]
let selectedFrame = selected.flatMap { rectAttribute($0.element, "AXFrame") }
let selectedPoint = center(selectedFrame)
let selectedState = selected.map { discreteState($0.element) }

emit([
    "event": "v170a_public_binary_state_probe",
    "status": "ok",
    "accessibility_api_trusted": trusted,
    "browser_bundle_id": app.bundleIdentifier ?? "",
    "browser_localized_name": app.localizedName ?? "",
    "browser_pid": app.processIdentifier,
    "requested_window_title": titleNeedle,
    "selected_window_title": stringAttribute(selectedWindow, kAXTitleAttribute),
    "window_frame": jsonValue(rectAttribute(selectedWindow, "AXFrame")),
    "target_kind": targetKindNeedle,
    "target_label": targetLabelNeedle,
    "target_found": selected != nil,
    "target_count": candidates.count,
    "target_candidates": candidates.prefix(12).map { elementPayload($0.element, depth: $0.depth, path: $0.path) },
    "target": selectedPayload,
    "target_point": jsonValue(selectedPoint),
    "target_state": jsonValue(selectedState?.0),
    "target_state_source": selectedState?.1 ?? "none",
    "target_raw_state": selectedState?.2 ?? [:],
    "scroll_to_visible_requested": scrollToVisibleRequested,
    "scroll_to_visible_status": scrollToVisibleStatus,
    "visited_count": visited,
    "fresh_remap_done": true,
    "posted": false,
    "physical_input_posted": false,
])
