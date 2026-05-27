import AppKit
import ApplicationServices
import Foundation

let env = ProcessInfo.processInfo.environment
let bundleIdNeedle = env["GENESIS_V155_BROWSER_BUNDLE_ID"] ?? "com.apple.Safari"
let browserNameNeedle = (env["GENESIS_V155_BROWSER_APP"] ?? "Safari").lowercased()
let titleNeedle = (env["GENESIS_V155_WINDOW_TITLE"] ?? "Genesis v15.5 Business Flow").lowercased()
let fieldNeedle = (env["GENESIS_V155_FIELD_TITLE"] ?? "Operator Code").lowercased()
let commitNeedle = (env["GENESIS_V155_COMMIT_TITLE"] ?? "Commit profile").lowercased()
let expectedStatusNeedle = (env["GENESIS_V155_EXPECT_STATUS_CONTAINS"] ?? "profile_saved").lowercased()
let inputValue = env["GENESIS_V155_OPERATOR_CODE"] ?? "GENESIS-V155"
let mutateRequested = env["GENESIS_V155_SET_FIELD"] == "1"
let mutateAuthorized = env["GENESIS_V155_MUTATE_CONFIRM"] == "GENESIS_V155_MUTATE_FORM_STATE"
let maxDepth = Int(env["GENESIS_V155_AX_MAX_DEPTH"] ?? "14") ?? 14
let maxNodes = Int(env["GENESIS_V155_AX_MAX_NODES"] ?? "2600") ?? 2600

func emit(_ payload: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
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

func jsonValue(_ value: Any?) -> Any {
    value ?? NSNull()
}

func haystack(_ element: AXUIElement) -> String {
    [
        stringAttribute(element, kAXTitleAttribute),
        stringAttribute(element, kAXDescriptionAttribute),
        stringAttribute(element, kAXValueAttribute),
    ].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
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
        "AXTextField",
        "AXPopUpButton",
        "AXHeading",
        "AXStaticText",
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
        "event": "v155_business_form_probe",
        "status": "error",
        "error": "browser app not running",
        "accessibility_api_trusted": trusted,
        "posted": false,
        "ax_mutation_attempted": false,
    ])
    exit(1)
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)
let matchingWindows = windows(of: appElement).filter { window in
    stringAttribute(window, kAXTitleAttribute).lowercased().contains(titleNeedle)
}

guard let selectedWindow = matchingWindows.first(where: { boolAttribute($0, kAXMainAttribute) || boolAttribute($0, kAXFocusedAttribute) }) ?? matchingWindows.first else {
    emit([
        "event": "v155_business_form_probe",
        "status": "error",
        "error": "matching browser window not found",
        "requested_window_title": titleNeedle,
        "accessibility_api_trusted": trusted,
        "posted": false,
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

let fieldItem = allItems.first { item in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    return role == "AXTextField" && haystack(item.element).lowercased().contains(fieldNeedle)
}

let commitItem = allItems.first { item in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    return role == "AXButton" && haystack(item.element).lowercased().contains(commitNeedle)
}

let statusItem = allItems.first { item in
    haystack(item.element).lowercased().contains(expectedStatusNeedle)
}

let modeItem = allItems.first { item in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    return role == "AXPopUpButton" || role == "AXComboBox"
}

var inputSetStatus = "not_attempted"
let preSetFieldValue = fieldItem.map { stringAttribute($0.element, kAXValueAttribute) } ?? ""
if mutateRequested {
    if mutateAuthorized, let fieldItem {
        let status = AXUIElementSetAttributeValue(fieldItem.element, kAXValueAttribute as CFString, inputValue as CFTypeRef)
        inputSetStatus = status == .success ? "success" : "error_\(status.rawValue)"
    } else {
        inputSetStatus = mutateAuthorized ? "field_not_found" : "not_authorized"
    }
}

let postSetFieldValue = fieldItem.map { stringAttribute($0.element, kAXValueAttribute) } ?? ""
let commitFrame = commitItem.flatMap { rectAttribute($0.element, "AXFrame") }
let commitPoint = commitFrame.map { ["x": $0["center_x"] ?? 0, "y": $0["center_y"] ?? 0] }

emit([
    "event": "v155_business_form_probe",
    "status": "ok",
    "accessibility_api_trusted": trusted,
    "selected_window_title": stringAttribute(selectedWindow, kAXTitleAttribute),
    "window_frame": jsonValue(rectAttribute(selectedWindow, "AXFrame")),
    "field_found": fieldItem != nil,
    "field": fieldItem.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "field_point": jsonValue(fieldItem.flatMap { rectAttribute($0.element, "AXFrame") }.map { ["x": $0["center_x"] ?? 0, "y": $0["center_y"] ?? 0] }),
    "field_value": postSetFieldValue,
    "field_value_before_set": preSetFieldValue,
    "input_value_requested": inputValue,
    "input_set_requested": mutateRequested,
    "input_set_authorized": mutateAuthorized,
    "input_set_status": inputSetStatus,
    "input_set_success": inputSetStatus == "success",
    "field_value_after_set": postSetFieldValue,
    "mode_control_found": modeItem != nil,
    "mode_control": modeItem.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "commit_found": commitItem != nil,
    "commit": commitItem.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "commit_point": jsonValue(commitPoint),
    "status_found": statusItem != nil,
    "status_node": statusItem.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "business_state_asserted": statusItem != nil,
    "visited_count": visited,
    "posted": false,
    "physical_input_posted": false,
    "ax_mutation_attempted": mutateRequested,
])
