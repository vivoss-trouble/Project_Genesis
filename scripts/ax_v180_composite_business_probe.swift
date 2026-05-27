import AppKit
import ApplicationServices
import Foundation

let env = ProcessInfo.processInfo.environment
let bundleIdNeedle = env["GENESIS_V180_BROWSER_BUNDLE_ID"] ?? "com.apple.Safari"
let browserNameNeedle = (env["GENESIS_V180_BROWSER_APP"] ?? "Safari").lowercased()
let titleNeedle = (env["GENESIS_V180_WINDOW_TITLE"] ?? "Genesis v18.0 Long-Clock Business").lowercased()
let fieldNeedle = (env["GENESIS_V180_FIELD_TITLE"] ?? "Operator Code").lowercased()
let checkboxNeedle = (env["GENESIS_V180_CHECKBOX_TITLE"] ?? "Enable survey mode").lowercased()
let comboNeedle = (env["GENESIS_V180_COMBO_TITLE"] ?? "Favorite Fruit").lowercased()
let optionNeedle = (env["GENESIS_V180_COMBO_VALUE"] ?? "Banana").lowercased()
let commitNeedle = (env["GENESIS_V180_COMMIT_TITLE"] ?? "Commit profile").lowercased()
let nextNeedle = (env["GENESIS_V180_NEXT_TITLE"] ?? "Next chapter").lowercased()
let expectedStatusNeedle = (env["GENESIS_V180_EXPECT_STATUS_CONTAINS"] ?? "profile_saved").lowercased()
let inputValue = env["GENESIS_V180_OPERATOR_CODE"] ?? "GENESIS-V18"
let comboValue = env["GENESIS_V180_COMBO_VALUE"] ?? "Banana"
let setFieldRequested = env["GENESIS_V180_SET_FIELD"] == "1"
let setComboRequested = env["GENESIS_V180_SET_COMBO"] == "1"
let mutationAuthorized = env["GENESIS_V180_MUTATE_CONFIRM"] == "GENESIS_V180_MUTATE_COMPOSITE_FORM"
let maxDepth = Int(env["GENESIS_V180_AX_MAX_DEPTH"] ?? "16") ?? 16
let maxNodes = Int(env["GENESIS_V180_AX_MAX_NODES"] ?? "3600") ?? 3600

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
        return ["true", "1", "yes", "checked", "selected", "on"].contains(string.lowercased())
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
        stringAttribute(element, "AXDOMIdentifier"),
    ].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

func parseDiscreteState(_ raw: String) -> Bool? {
    let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if ["true", "1", "yes", "checked", "selected", "on"].contains(lowered) { return true }
    if ["false", "0", "no", "unchecked", "unselected", "off"].contains(lowered) { return false }
    return nil
}

func discreteState(_ element: AXUIElement) -> (Bool?, String, [String: Any]) {
    let attributes = ["AXChecked", kAXValueAttribute, "AXSelected", "AXARIAChecked", "AXAriaChecked"]
    var raw: [String: Any] = [:]
    for attribute in attributes {
        let (status, value) = copyAttribute(element, attribute)
        guard status == .success, let value else {
            raw[attribute] = ["status": status.rawValue]
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
    let (state, source, raw) = discreteState(element)
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
        "child_count": children(of: element).count,
        "state": jsonValue(state),
        "state_source": source,
        "raw_state": raw,
    ]
}

func pointPayload(_ item: QueueItem?) -> Any {
    guard let item, let frame = rectAttribute(item.element, "AXFrame") else { return NSNull() }
    return ["x": frame["center_x"] ?? 0, "y": frame["center_y"] ?? 0]
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
        "AXLink",
        "AXButton",
        "AXTextField",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXComboBox",
        "AXStaticText",
        "AXHeading",
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
        "event": "v180_composite_business_probe",
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
        "event": "v180_composite_business_probe",
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
    stringAttribute(item.element, kAXRoleAttribute) == "AXTextField"
        && haystack(item.element).lowercased().contains(fieldNeedle)
}

let checkboxItem = allItems.first { item in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    return role == "AXCheckBox" && haystack(item.element).lowercased().contains(checkboxNeedle)
}

let comboItem = allItems.first { item in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    let label = haystack(item.element).lowercased()
    return (role == "AXPopUpButton" || role == "AXComboBox" || role == "AXButton")
        && label.contains(comboNeedle)
}

let optionItem = allItems.first { item in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    let label = haystack(item.element).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return role == "AXButton" && label.contains(optionNeedle)
}

let commitItem = allItems.first { item in
    stringAttribute(item.element, kAXRoleAttribute) == "AXButton"
        && haystack(item.element).lowercased().contains(commitNeedle)
}

let nextItem = allItems.first { item in
    stringAttribute(item.element, kAXRoleAttribute) == "AXButton"
        && haystack(item.element).lowercased().contains(nextNeedle)
}

let statusItem = allItems.first { item in
    haystack(item.element).lowercased().contains(expectedStatusNeedle)
}

let preSetFieldValue = fieldItem.map { stringAttribute($0.element, kAXValueAttribute) } ?? ""
var fieldSetStatus = "not_requested"
if setFieldRequested {
    if mutationAuthorized, let fieldItem {
        let status = AXUIElementSetAttributeValue(fieldItem.element, kAXValueAttribute as CFString, inputValue as CFTypeRef)
        fieldSetStatus = status == .success ? "success" : "error_\(status.rawValue)"
    } else {
        fieldSetStatus = mutationAuthorized ? "field_not_found" : "not_authorized"
    }
}

let preSetComboValue = comboItem.map { stringAttribute($0.element, kAXValueAttribute) } ?? ""
var comboSetStatus = "not_requested"
if setComboRequested {
    if mutationAuthorized, let comboItem {
        let status = AXUIElementSetAttributeValue(comboItem.element, kAXValueAttribute as CFString, comboValue as CFTypeRef)
        comboSetStatus = status == .success ? "success" : "error_\(status.rawValue)"
    } else {
        comboSetStatus = mutationAuthorized ? "combo_not_found" : "not_authorized"
    }
}

let fieldValue = fieldItem.map { stringAttribute($0.element, kAXValueAttribute) } ?? ""
let comboCurrentValue = comboItem.map {
    let value = stringAttribute($0.element, kAXValueAttribute)
    return value.isEmpty ? haystack($0.element) : value
} ?? ""
let (checkboxState, checkboxStateSource, checkboxRawState) = checkboxItem.map { discreteState($0.element) } ?? (nil, "none", [:])

emit([
    "event": "v180_composite_business_probe",
    "status": "ok",
    "accessibility_api_trusted": trusted,
    "selected_window_title": stringAttribute(selectedWindow, kAXTitleAttribute),
    "window_frame": jsonValue(rectAttribute(selectedWindow, "AXFrame")),
    "field_found": fieldItem != nil,
    "field": fieldItem.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "field_point": pointPayload(fieldItem),
    "field_value": fieldValue,
    "field_value_before_set": preSetFieldValue,
    "field_set_requested": setFieldRequested,
    "field_set_authorized": mutationAuthorized,
    "field_set_status": fieldSetStatus,
    "field_set_success": fieldSetStatus == "success",
    "checkbox_found": checkboxItem != nil,
    "checkbox": checkboxItem.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "checkbox_point": pointPayload(checkboxItem),
    "checkbox_state": jsonValue(checkboxState),
    "checkbox_state_source": checkboxStateSource,
    "checkbox_raw_state": checkboxRawState,
    "combo_found": comboItem != nil,
    "combo": comboItem.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "combo_point": pointPayload(comboItem),
    "combo_value": comboCurrentValue,
    "combo_value_before_set": preSetComboValue,
    "combo_set_requested": setComboRequested,
    "combo_set_authorized": mutationAuthorized,
    "combo_set_status": comboSetStatus,
    "combo_set_success": comboSetStatus == "success",
    "option_found": optionItem != nil,
    "option": optionItem.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "option_point": pointPayload(optionItem),
    "option_label": comboValue,
    "commit_found": commitItem != nil,
    "commit": commitItem.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "commit_point": pointPayload(commitItem),
    "next_found": nextItem != nil,
    "next": nextItem.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "next_point": pointPayload(nextItem),
    "status_found": statusItem != nil,
    "status_node": statusItem.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "business_state_asserted": statusItem != nil,
    "visited_count": visited,
    "posted": false,
    "physical_input_posted": false,
    "ax_mutation_attempted": setFieldRequested || setComboRequested,
])
