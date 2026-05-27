import AppKit
import ApplicationServices
import Foundation

let env = ProcessInfo.processInfo.environment
let bundleIdNeedle = env["GENESIS_V170B_BROWSER_BUNDLE_ID"] ?? "com.apple.Safari"
let browserNameNeedle = (env["GENESIS_V170B_BROWSER_APP"] ?? "Safari").lowercased()
let titleNeedle = (env["GENESIS_V170B_WINDOW_TITLE"] ?? "Select-Only Combobox").lowercased()
let comboLabelNeedle = (env["GENESIS_V170B_COMBO_LABEL"] ?? "Favorite Fruit").lowercased()
let optionLabelNeedle = (env["GENESIS_V170B_OPTION_LABEL"] ?? "Banana").lowercased()
let scrollToVisibleRequested = env["GENESIS_V170B_SCROLL_TO_VISIBLE"] == "1"
let scrollToVisibleAuthorized = env["GENESIS_V170B_SCROLL_TO_VISIBLE_CONFIRM"] == "GENESIS_V170B_SCROLL_TO_VISIBLE_PUBLIC_COMBOBOX"
let maxDepth = Int(env["GENESIS_V170B_AX_MAX_DEPTH"] ?? "14") ?? 14
let maxNodes = Int(env["GENESIS_V170B_AX_MAX_NODES"] ?? "5200") ?? 5200

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
        return ["true", "1", "yes", "selected", "expanded"].contains(string.lowercased())
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

func center(_ frame: [String: Double]?) -> [String: Double]? {
    guard let frame else { return nil }
    return ["x": frame["center_x"] ?? 0, "y": frame["center_y"] ?? 0]
}

func haystack(_ element: AXUIElement) -> String {
    [
        stringAttribute(element, kAXTitleAttribute),
        stringAttribute(element, kAXDescriptionAttribute),
        stringAttribute(element, kAXValueAttribute),
        stringAttribute(element, "AXDOMIdentifier"),
    ].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

func normalizedLabels(_ element: AXUIElement) -> [String] {
    [
        stringAttribute(element, kAXTitleAttribute),
        stringAttribute(element, kAXDescriptionAttribute),
        stringAttribute(element, kAXValueAttribute),
        stringAttribute(element, "AXDOMIdentifier"),
    ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }
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
        "AXSplitGroup",
        "AXScrollArea",
        "AXWebArea",
        "AXGroup",
        "AXOpaqueProviderGroup",
        "AXTabGroup",
        "AXList",
        "AXRow",
        "AXColumn",
        "AXCell",
        "AXComboBox",
        "AXPopUpButton",
        "AXMenu",
        "AXMenuItem",
        "AXButton",
        "AXStaticText",
        "AXHeading",
    ].contains(role)
}

func elementPayload(_ element: AXUIElement, depth: Int, path: [Int]) -> [String: Any] {
    [
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
    ]
}

func isDescendantPath(_ child: [Int], of parent: [Int]) -> Bool {
    guard child.count > parent.count else { return false }
    return Array(child.prefix(parent.count)) == parent
}

func descendants(of element: AXUIElement, depth: Int = 0, maxDepth: Int = 4) -> [AXUIElement] {
    guard depth < maxDepth else { return [] }
    var result: [AXUIElement] = []
    for child in children(of: element) {
        result.append(child)
        result.append(contentsOf: descendants(of: child, depth: depth + 1, maxDepth: maxDepth))
    }
    return result
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
        "event": "v170b_public_combobox_probe",
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
        "event": "v170b_public_combobox_probe",
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

let comboItems = allItems.filter { item in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    let label = haystack(item.element).lowercased()
    let frame = rectAttribute(item.element, "AXFrame")
    return role == "AXComboBox"
        && label.contains(comboLabelNeedle)
        && (frame?["area"] ?? 0) > 0
}

let selectedCombo = comboItems.min { lhs, rhs in
    let lhsArea = rectAttribute(lhs.element, "AXFrame")?["area"] ?? Double.greatestFiniteMagnitude
    let rhsArea = rectAttribute(rhs.element, "AXFrame")?["area"] ?? Double.greatestFiniteMagnitude
    return lhsArea < rhsArea
}

var scrollToVisibleStatus = "not_requested"
if scrollToVisibleRequested {
    if scrollToVisibleAuthorized, let selectedCombo {
        let status = AXUIElementPerformAction(selectedCombo.element, "AXScrollToVisible" as CFString)
        scrollToVisibleStatus = statusName(status)
        usleep(180_000)
    } else {
        scrollToVisibleStatus = scrollToVisibleAuthorized ? "target_missing" : "not_authorized"
    }
}

let comboPayload = selectedCombo.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:]
let comboFrame = selectedCombo.flatMap { rectAttribute($0.element, "AXFrame") }
let comboPoint = center(comboFrame)
let comboValue = selectedCombo.map { stringAttribute($0.element, kAXValueAttribute) } ?? ""

let listItems = allItems.filter { item in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    let label = haystack(item.element).lowercased()
    let frame = rectAttribute(item.element, "AXFrame")
    return role == "AXList"
        && label.contains(comboLabelNeedle)
        && (frame?["area"] ?? 0) > 0
}

let selectedList = listItems.min { lhs, rhs in
    let lhsDistance = abs((rectAttribute(lhs.element, "AXFrame")?["center_y"] ?? 0) - (comboFrame?["center_y"] ?? 0))
    let rhsDistance = abs((rectAttribute(rhs.element, "AXFrame")?["center_y"] ?? 0) - (comboFrame?["center_y"] ?? 0))
    return lhsDistance < rhsDistance
}

let optionElements: [AXUIElement]
if let selectedList {
    optionElements = descendants(of: selectedList.element)
} else {
    optionElements = allItems.map(\.element)
}

let optionItems = optionElements.compactMap { element -> QueueItem? in
    let role = stringAttribute(element, kAXRoleAttribute)
    guard ["AXStaticText", "AXMenuItem", "AXOption", "AXButton"].contains(role) else { return nil }
    guard normalizedLabels(element).contains(optionLabelNeedle) else { return nil }
    if let item = allItems.first(where: { CFEqual($0.element, element) }) {
        return item
    }
    return QueueItem(element: element, depth: -1, path: [])
}

let selectedOption = optionItems.min { lhs, rhs in
    let lhsFrame = rectAttribute(lhs.element, "AXFrame")
    let rhsFrame = rectAttribute(rhs.element, "AXFrame")
    return (lhsFrame?["area"] ?? Double.greatestFiniteMagnitude) < (rhsFrame?["area"] ?? Double.greatestFiniteMagnitude)
}

let selectedListPayload = selectedList.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:]
let selectedOptionPayload = selectedOption.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:]
let optionFrame = selectedOption.flatMap { rectAttribute($0.element, "AXFrame") }
let optionPoint = center(optionFrame)
let listChildrenPayload: [[String: Any]] = selectedList.map { listItem in
    children(of: listItem.element).enumerated().map { index, child in
        [
            "index": index,
            "role": stringAttribute(child, kAXRoleAttribute),
            "title": stringAttribute(child, kAXTitleAttribute),
            "description": stringAttribute(child, kAXDescriptionAttribute),
            "value": stringAttribute(child, kAXValueAttribute),
            "frame": jsonValue(rectAttribute(child, "AXFrame")),
        ]
    }
} ?? []

emit([
    "event": "v170b_public_combobox_probe",
    "status": "ok",
    "accessibility_api_trusted": trusted,
    "browser_bundle_id": app.bundleIdentifier ?? "",
    "browser_localized_name": app.localizedName ?? "",
    "browser_pid": app.processIdentifier,
    "requested_window_title": titleNeedle,
    "selected_window_title": stringAttribute(selectedWindow, kAXTitleAttribute),
    "window_frame": jsonValue(rectAttribute(selectedWindow, "AXFrame")),
    "combo_label": comboLabelNeedle,
    "option_label": optionLabelNeedle,
    "combo_found": selectedCombo != nil,
    "combo_count": comboItems.count,
    "combo": comboPayload,
    "combo_point": jsonValue(comboPoint),
    "combo_value": comboValue,
    "listbox_found": selectedList != nil,
    "listbox": selectedListPayload,
    "listbox_children": listChildrenPayload,
    "option_found": selectedOption != nil,
    "option_count": optionItems.count,
    "option": selectedOptionPayload,
    "option_point": jsonValue(optionPoint),
    "popup_expanded": selectedList != nil && selectedOption != nil,
    "scroll_to_visible_requested": scrollToVisibleRequested,
    "scroll_to_visible_status": scrollToVisibleStatus,
    "fresh_remap_done": true,
    "visited_count": visited,
    "posted": false,
    "physical_input_posted": false,
])
