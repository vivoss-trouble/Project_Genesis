import AppKit
import ApplicationServices
import Foundation

let env = ProcessInfo.processInfo.environment
let bundleIdNeedle = env["GENESIS_V210B_BROWSER_BUNDLE_ID"] ?? "com.apple.Safari"
let browserNameNeedle = (env["GENESIS_V210B_BROWSER_APP"] ?? "Safari").lowercased()
let titleNeedle = (env["GENESIS_V210B_WINDOW_TITLE"] ?? "Wikipedia").lowercased()
let fieldNeedle = (env["GENESIS_V210B_SEARCH_FIELD_TITLE"] ?? "Search Wikipedia").lowercased()
let commitNeedle = (env["GENESIS_V210B_SEARCH_COMMIT_TITLE"] ?? "Search").lowercased()
let inputValue = env["GENESIS_V210B_SEARCH_QUERY"] ?? "OpenAI"
let mutateRequested = env["GENESIS_V210B_SET_FIELD"] == "1"
let mutateAuthorized = env["GENESIS_V210B_MUTATE_CONFIRM"] == "GENESIS_V210B_MUTATE_WIKIPEDIA_SEARCH"
let pressSuggestionRequested = env["GENESIS_V210B_PRESS_SUGGESTION"] == "1"
let pressSuggestionAuthorized = env["GENESIS_V210B_COMMIT_CONFIRM"] == "GENESIS_V210B_COMMIT_WIKIPEDIA_SEARCH"
let maxDepth = Int(env["GENESIS_V210B_AX_MAX_DEPTH"] ?? "14") ?? 14
let maxNodes = Int(env["GENESIS_V210B_AX_MAX_NODES"] ?? "5000") ?? 5000

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

func haystack(_ element: AXUIElement) -> String {
    [
        stringAttribute(element, kAXTitleAttribute),
        stringAttribute(element, kAXDescriptionAttribute),
        stringAttribute(element, kAXValueAttribute),
        stringAttribute(element, "AXDOMIdentifier"),
        stringAttribute(element, "AXDOMClassList"),
    ].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

func center(_ frame: [String: Double]?) -> [String: Double]? {
    guard let frame else { return nil }
    return ["x": frame["center_x"] ?? 0, "y": frame["center_y"] ?? 0]
}

func visibleFrame(_ frame: [String: Double]?) -> Bool {
    guard let frame else { return false }
    return (frame["width"] ?? 0) > 2 && (frame["height"] ?? 0) > 2 && (frame["area"] ?? 0) > 8
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
        "child_count": children(of: element).count,
    ]
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
        "AXComboBox",
        "AXPopUpButton",
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
        "event": "v210b_wikipedia_search_probe",
        "status": "error",
        "error": "browser app not running",
        "accessibility_api_trusted": trusted,
        "posted": false,
        "physical_input_posted": false,
        "ax_mutation_attempted": false,
    ])
    exit(1)
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)
let windowList = windows(of: appElement)
let matchingWindows = windowList.filter { window in
    let title = stringAttribute(window, kAXTitleAttribute).lowercased()
    return titleNeedle.isEmpty || title.contains(titleNeedle)
}
let selectedWindow = matchingWindows.first { window in
    boolAttribute(window, kAXMainAttribute) || boolAttribute(window, kAXFocusedAttribute)
} ?? matchingWindows.first ?? windowList.first

guard let selectedWindow else {
    emit([
        "event": "v210b_wikipedia_search_probe",
        "status": "error",
        "error": "matching browser window not found",
        "requested_window_title": titleNeedle,
        "window_titles": windowList.map { stringAttribute($0, kAXTitleAttribute) },
        "accessibility_api_trusted": trusted,
        "posted": false,
        "physical_input_posted": false,
        "ax_mutation_attempted": false,
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

let textFields = allItems.filter { item in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    let frame = rectAttribute(item.element, "AXFrame")
    guard (role == "AXTextField" || role == "AXTextArea"), visibleFrame(frame) else { return false }
    return true
}

let selectedField = textFields.first { item in
    let text = haystack(item.element).lowercased()
    return text.contains(fieldNeedle)
        || text.contains("search wikipedia")
        || text.contains("search")
} ?? textFields.first

let buttons = allItems.filter { item in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    let actions = actionNames(item.element)
    let frame = rectAttribute(item.element, "AXFrame")
    guard visibleFrame(frame) else { return false }
    return role == "AXButton" || actions.contains("AXPress")
}

// Wikipedia's AX tree can expose a huge offscreen "Search" button proxy whose
// frame is not a safe physical target. Treat the search field itself as the
// commit anchor; the runner focuses it and submits with Return.
let selectedCommit = selectedField

var inputSetStatus = "not_attempted"
let preSetFieldValue = selectedField.map { stringAttribute($0.element, kAXValueAttribute) } ?? ""
if mutateRequested {
    if mutateAuthorized, let selectedField {
        let status = AXUIElementSetAttributeValue(selectedField.element, kAXValueAttribute as CFString, inputValue as CFTypeRef)
        inputSetStatus = statusName(status)
    } else {
        inputSetStatus = mutateAuthorized ? "field_not_found" : "not_authorized"
    }
}

let postSetFieldValue = selectedField.map { stringAttribute($0.element, kAXValueAttribute) } ?? ""
let fieldFrame = selectedField.flatMap { rectAttribute($0.element, "AXFrame") }
let commitFrame = selectedCommit.flatMap { rectAttribute($0.element, "AXFrame") }
let suggestionCandidates = allItems.filter { item in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    let frame = rectAttribute(item.element, "AXFrame")
    guard ["AXLink", "AXStaticText", "AXButton", "AXGroup"].contains(role),
          visibleFrame(frame) else { return false }
    let text = haystack(item.element).lowercased()
    guard text.contains(inputValue.lowercased()) else { return false }
    if let fieldFrame, let frame {
        let fieldBottom = (fieldFrame["y"] ?? 0) + (fieldFrame["height"] ?? 0)
        let centerY = frame["center_y"] ?? 0
        return centerY > fieldBottom && centerY < fieldBottom + 260
    }
    return true
}.sorted { lhs, rhs in
    let lhsFrame = rectAttribute(lhs.element, "AXFrame")
    let rhsFrame = rectAttribute(rhs.element, "AXFrame")
    let lhsRole = stringAttribute(lhs.element, kAXRoleAttribute)
    let rhsRole = stringAttribute(rhs.element, kAXRoleAttribute)
    let roleRank: (String) -> Int = { role in
        if role == "AXLink" { return 0 }
        if role == "AXStaticText" { return 1 }
        if role == "AXButton" { return 2 }
        return 3
    }
    let lhsRank = roleRank(lhsRole)
    let rhsRank = roleRank(rhsRole)
    if lhsRank != rhsRank { return lhsRank < rhsRank }
    return (lhsFrame?["center_y"] ?? 0) < (rhsFrame?["center_y"] ?? 0)
}
let selectedSuggestion = suggestionCandidates.first
let suggestionFrame = selectedSuggestion.flatMap { rectAttribute($0.element, "AXFrame") }
var suggestionPressStatus = "not_attempted"
if pressSuggestionRequested {
    if pressSuggestionAuthorized, let selectedSuggestion {
        let status = AXUIElementPerformAction(selectedSuggestion.element, kAXPressAction as CFString)
        suggestionPressStatus = statusName(status)
    } else {
        suggestionPressStatus = pressSuggestionAuthorized ? "suggestion_not_found" : "not_authorized"
    }
}
let titleText = stringAttribute(selectedWindow, kAXTitleAttribute)
let statusAsserted = titleText.lowercased().contains(inputValue.lowercased())
    || allItems.contains { item in
        haystack(item.element).lowercased().contains(inputValue.lowercased())
    }

emit([
    "event": "v210b_wikipedia_search_probe",
    "status": "ok",
    "accessibility_api_trusted": trusted,
    "browser_bundle_id": app.bundleIdentifier ?? "",
    "browser_localized_name": app.localizedName ?? "",
    "browser_pid": app.processIdentifier,
    "selected_window_title": titleText,
    "window_frame": jsonValue(rectAttribute(selectedWindow, "AXFrame")),
    "field_label_requested": fieldNeedle,
    "field_candidate_count": textFields.count,
    "field_candidates": textFields.prefix(12).map { elementPayload($0.element, depth: $0.depth, path: $0.path) },
    "field_found": selectedField != nil,
    "field": selectedField.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "field_point": jsonValue(center(fieldFrame)),
    "field_value": postSetFieldValue,
    "field_value_before_set": preSetFieldValue,
    "field_value_after_set": postSetFieldValue,
    "input_value_requested": inputValue,
    "input_set_requested": mutateRequested,
    "input_set_authorized": mutateAuthorized,
    "input_set_status": inputSetStatus,
    "input_set_success": inputSetStatus == "success",
    "commit_title_requested": commitNeedle,
    "commit_candidate_count": selectedCommit == nil ? 0 : 1,
    "commit_candidates": buttons.prefix(16).map { elementPayload($0.element, depth: $0.depth, path: $0.path) },
    "commit_found": selectedCommit != nil,
    "commit": selectedCommit.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "commit_point": jsonValue(center(commitFrame)),
    "suggestion_candidate_count": suggestionCandidates.count,
    "suggestion_candidates": suggestionCandidates.prefix(8).map { elementPayload($0.element, depth: $0.depth, path: $0.path) },
    "suggestion_found": selectedSuggestion != nil,
    "suggestion": selectedSuggestion.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "suggestion_point": jsonValue(center(suggestionFrame)),
    "suggestion_press_requested": pressSuggestionRequested,
    "suggestion_press_authorized": pressSuggestionAuthorized,
    "suggestion_press_status": suggestionPressStatus,
    "suggestion_press_success": suggestionPressStatus == "success",
    "business_state_asserted": statusAsserted,
    "visited_count": visited,
    "posted": false,
    "physical_input_posted": false,
    "ax_mutation_attempted": mutateRequested,
])
