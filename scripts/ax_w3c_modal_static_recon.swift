import AppKit
import ApplicationServices
import Foundation

let env = ProcessInfo.processInfo.environment
let bundleIdNeedle = env["GENESIS_V145A2_BROWSER_BUNDLE_ID"] ?? "com.apple.Safari"
let browserNameNeedle = (env["GENESIS_V145A2_BROWSER_APP"] ?? "Safari").lowercased()
let titleNeedle = (env["GENESIS_V145A2_WINDOW_TITLE"] ?? "Modal Dialog Example").lowercased()
let triggerNeedle = (env["GENESIS_V145A2_TRIGGER_TITLE"] ?? "Add Delivery Address").lowercased()
let dialogNeedles = (env["GENESIS_V145A2_DIALOG_NEEDLES"] ?? "Add Delivery Address,Verification Result,Address Added,End of the Road")
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
let maxDepth = Int(env["GENESIS_V145A2_AX_MAX_DEPTH"] ?? "12") ?? 12
let maxNodes = Int(env["GENESIS_V145A2_AX_MAX_NODES"] ?? "3200") ?? 3200
let maxMatches = Int(env["GENESIS_V145A2_MAX_MATCHES"] ?? "20") ?? 20

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
        "area": Double(rect.width * rect.height),
    ]
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

func haystack(_ element: AXUIElement) -> String {
    [
        stringAttribute(element, kAXTitleAttribute),
        stringAttribute(element, kAXDescriptionAttribute),
        stringAttribute(element, kAXValueAttribute),
    ].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
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
        "event": "v145a2_w3c_modal_static_recon",
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
let windowTitles = windowList.map { stringAttribute($0, kAXTitleAttribute) }

guard let selectedWindow else {
    emit([
        "event": "v145a2_w3c_modal_static_recon",
        "status": "error",
        "error": "matching browser window not found",
        "requested_window_title": titleNeedle,
        "window_titles": windowTitles,
        "accessibility_api_trusted": trusted,
        "posted": false,
        "physical_input_posted": false,
        "ax_mutation_attempted": false,
    ])
    exit(1)
}

var visited = 0
var triggerMatches: [[String: Any]] = []
var dialogMatches: [[String: Any]] = []
var queue = [QueueItem(element: selectedWindow, depth: 0, path: [])]

while !queue.isEmpty && visited < maxNodes {
    let item = queue.removeFirst()
    visited += 1
    let role = stringAttribute(item.element, kAXRoleAttribute)
    let subrole = stringAttribute(item.element, kAXSubroleAttribute)
    let text = haystack(item.element)
    let textLower = text.lowercased()
    let actions = actionNames(item.element)

    if triggerMatches.count < maxMatches
        && actions.contains("AXPress")
        && textLower.contains(triggerNeedle) {
        triggerMatches.append(elementPayload(item.element, depth: item.depth, path: item.path))
    }

    let dialogLike = role == "AXDialog"
        || subrole == "AXApplicationDialog"
        || (role == "AXGroup" && dialogNeedles.contains { textLower.contains($0) } && actions.contains("AXCancel"))
    if dialogMatches.count < maxMatches && dialogLike {
        dialogMatches.append(elementPayload(item.element, depth: item.depth, path: item.path))
    }

    guard shouldDescend(role: role, depth: item.depth) else { continue }
    for (index, child) in children(of: item.element).enumerated() {
        queue.append(QueueItem(element: child, depth: item.depth + 1, path: item.path + [index]))
    }
}

emit([
    "event": "v145a2_w3c_modal_static_recon",
    "status": "ok",
    "accessibility_api_trusted": trusted,
    "browser_bundle_id": app.bundleIdentifier ?? "",
    "browser_localized_name": app.localizedName ?? "",
    "browser_pid": app.processIdentifier,
    "selected_window_title": stringAttribute(selectedWindow, kAXTitleAttribute),
    "requested_window_title": titleNeedle,
    "trigger_title": triggerNeedle,
    "trigger_found": !triggerMatches.isEmpty,
    "trigger_candidate_count": triggerMatches.count,
    "trigger_candidates": triggerMatches,
    "public_obstacle_seen": !dialogMatches.isEmpty,
    "occluder_kind": dialogMatches.isEmpty ? "none" : "modal",
    "dialog_candidate_count": dialogMatches.count,
    "dialog_candidates": dialogMatches,
    "candidate_count": 0,
    "legal_candidate_count": 0,
    "safe_to_arm": false,
    "visited_count": visited,
    "posted": false,
    "physical_input_posted": false,
    "ax_mutation_attempted": false,
])
