import AppKit
import ApplicationServices
import Foundation

let env = ProcessInfo.processInfo.environment
let bundleIdNeedle = env["GENESIS_V160_BROWSER_BUNDLE_ID"] ?? "com.apple.Safari"
let browserNameNeedle = (env["GENESIS_V160_BROWSER_APP"] ?? "Safari").lowercased()
let titleNeedle = (env["GENESIS_V160_WINDOW_TITLE"] ?? "Modal Dialog Example").lowercased()
let formDialogNeedle = (env["GENESIS_V160_FORM_DIALOG_TITLE"] ?? "Add Delivery Address").lowercased()
let fieldNeedle = (env["GENESIS_V160_FIELD_LABEL"] ?? "Street").lowercased()
let commitNeedle = (env["GENESIS_V160_COMMIT_TITLE"] ?? "Verify Address").lowercased()
let expectedStatusNeedle = (env["GENESIS_V160_EXPECT_STATUS_CONTAINS"] ?? "Verification Result").lowercased()
let inputValue = env["GENESIS_V160_INPUT_VALUE"] ?? "42 Genesis Way"
let mutateRequested = env["GENESIS_V160_SET_FIELD"] == "1"
let mutateAuthorized = env["GENESIS_V160_MUTATE_CONFIRM"] == "GENESIS_V160_MUTATE_PUBLIC_FORM_STATE"
let maxDepth = Int(env["GENESIS_V160_AX_MAX_DEPTH"] ?? "14") ?? 14
let maxNodes = Int(env["GENESIS_V160_AX_MAX_NODES"] ?? "3600") ?? 3600

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
    guard status == .success, let string = value as? String else { return "" }
    return string
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
    ].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

func isDescendantPath(_ path: [Int], of ancestor: [Int]) -> Bool {
    guard path.count > ancestor.count else { return false }
    return Array(path.prefix(ancestor.count)) == ancestor
}

func containsPoint(_ rect: [String: Double]?, _ point: [String: Double]?) -> Bool {
    guard let rect, let point, let x = point["x"], let y = point["y"] else { return false }
    return x >= (rect["x"] ?? 0)
        && x <= (rect["x"] ?? 0) + (rect["width"] ?? 0)
        && y >= (rect["y"] ?? 0)
        && y <= (rect["y"] ?? 0) + (rect["height"] ?? 0)
}

func center(_ frame: [String: Double]?) -> [String: Double]? {
    guard let frame else { return nil }
    return ["x": frame["center_x"] ?? 0, "y": frame["center_y"] ?? 0]
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
        "event": "v160_public_business_form_probe",
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
    stringAttribute(window, kAXTitleAttribute).lowercased().contains(titleNeedle)
}
let selectedWindow = matchingWindows.first { window in
    boolAttribute(window, kAXMainAttribute) || boolAttribute(window, kAXFocusedAttribute)
} ?? matchingWindows.first

guard let selectedWindow else {
    emit([
        "event": "v160_public_business_form_probe",
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

let formDialogs = allItems.filter { item in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    let subrole = stringAttribute(item.element, kAXSubroleAttribute)
    let text = haystack(item.element).lowercased()
    return role == "AXDialog"
        || subrole == "AXApplicationDialog"
        || (role == "AXGroup" && text.contains(formDialogNeedle))
}
let selectedFormDialog = formDialogs.min { lhs, rhs in
    let lhsArea = rectAttribute(lhs.element, "AXFrame")?["area"] ?? Double.greatestFiniteMagnitude
    let rhsArea = rectAttribute(rhs.element, "AXFrame")?["area"] ?? Double.greatestFiniteMagnitude
    return lhsArea < rhsArea
}
let selectedFormDialogFrame = selectedFormDialog.flatMap { rectAttribute($0.element, "AXFrame") }

func inferredLabel(for field: QueueItem) -> String {
    guard let fieldFrame = rectAttribute(field.element, "AXFrame"),
          let fieldX = fieldFrame["x"],
          let fieldY = fieldFrame["center_y"] else { return haystack(field.element) }
    let labelCandidates = allItems.compactMap { item -> (String, Double)? in
        let role = stringAttribute(item.element, kAXRoleAttribute)
        guard role == "AXStaticText" || role == "AXHeading" else { return nil }
        guard let dialog = selectedFormDialog, isDescendantPath(item.path, of: dialog.path) else { return nil }
        guard let frame = rectAttribute(item.element, "AXFrame"),
              let centerY = frame["center_y"],
              let centerX = frame["center_x"] else { return nil }
        guard centerX <= fieldX + 8 else { return nil }
        let dy = abs(centerY - fieldY)
        guard dy <= 28 else { return nil }
        let text = haystack(item.element).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (text, dy)
    }
    return labelCandidates.min { lhs, rhs in lhs.1 < rhs.1 }?.0 ?? haystack(field.element)
}

var fieldCandidates: [[String: Any]] = []
var fieldItems: [(QueueItem, String)] = []
if let dialog = selectedFormDialog {
    for item in allItems {
        let role = stringAttribute(item.element, kAXRoleAttribute)
        guard role == "AXTextField" || role == "AXTextArea" else { continue }
        guard isDescendantPath(item.path, of: dialog.path) else { continue }
        let frame = rectAttribute(item.element, "AXFrame")
        guard containsPoint(selectedFormDialogFrame, center(frame)) else { continue }
        let label = inferredLabel(for: item)
        var payload = elementPayload(item.element, depth: item.depth, path: item.path)
        payload["inferred_label"] = label
        payload["label_match"] = label.lowercased().contains(fieldNeedle)
        fieldCandidates.append(payload)
        fieldItems.append((item, label))
    }
}

let selectedFieldPair = fieldItems.first { (_, label) in
    label.lowercased().contains(fieldNeedle)
} ?? fieldItems.first
let selectedField = selectedFieldPair?.0
let selectedFieldLabel = selectedFieldPair?.1 ?? ""

let commitItem = allItems.first { item in
    guard let dialog = selectedFormDialog, isDescendantPath(item.path, of: dialog.path) else { return false }
    let role = stringAttribute(item.element, kAXRoleAttribute)
    let text = haystack(item.element).lowercased()
    return role == "AXButton" && text.contains(commitNeedle)
}

let statusItems = allItems.filter { item in
    haystack(item.element).lowercased().contains(expectedStatusNeedle)
}

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
let commitFrame = commitItem.flatMap { rectAttribute($0.element, "AXFrame") }

emit([
    "event": "v160_public_business_form_probe",
    "status": "ok",
    "accessibility_api_trusted": trusted,
    "browser_bundle_id": app.bundleIdentifier ?? "",
    "browser_localized_name": app.localizedName ?? "",
    "browser_pid": app.processIdentifier,
    "selected_window_title": stringAttribute(selectedWindow, kAXTitleAttribute),
    "window_frame": jsonValue(rectAttribute(selectedWindow, "AXFrame")),
    "form_dialog_found": selectedFormDialog != nil,
    "form_dialog": selectedFormDialog.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "field_label_requested": fieldNeedle,
    "field_candidate_count": fieldCandidates.count,
    "field_candidates": fieldCandidates,
    "field_found": selectedField != nil,
    "field_label": selectedFieldLabel,
    "field": selectedField.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "field_point": jsonValue(center(fieldFrame)),
    "field_value": postSetFieldValue,
    "field_value_before_set": preSetFieldValue,
    "input_value_requested": inputValue,
    "input_set_requested": mutateRequested,
    "input_set_authorized": mutateAuthorized,
    "input_set_status": inputSetStatus,
    "input_set_success": inputSetStatus == "success",
    "field_value_after_set": postSetFieldValue,
    "commit_title_requested": commitNeedle,
    "commit_found": commitItem != nil,
    "commit": commitItem.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "commit_point": jsonValue(center(commitFrame)),
    "business_state_asserted": !statusItems.isEmpty,
    "status_match_count": statusItems.count,
    "status_nodes": statusItems.prefix(10).map { elementPayload($0.element, depth: $0.depth, path: $0.path) },
    "expected_status_contains": expectedStatusNeedle,
    "visited_count": visited,
    "posted": false,
    "physical_input_posted": false,
    "ax_mutation_attempted": mutateRequested,
])
