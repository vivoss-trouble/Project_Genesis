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
let whitelist = Set((env["GENESIS_V145A2_WHITELIST"] ?? "cancel,close,dismiss,not now,reject all,decline")
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
let blacklist = (env["GENESIS_V145A2_BLACKLIST"] ?? "accept,subscribe,continue,agree,add,submit,save")
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
let roleWhitelist = Set((env["GENESIS_V145A2_ROLE_WHITELIST"] ?? "AXButton,AXLink")
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
let maxDepth = Int(env["GENESIS_V145A2_AX_MAX_DEPTH"] ?? "12") ?? 12
let maxNodes = Int(env["GENESIS_V145A2_AX_MAX_NODES"] ?? "3200") ?? 3200
let maxMatches = Int(env["GENESIS_V145A2_MAX_MATCHES"] ?? "20") ?? 20
let triggerExecute = env["GENESIS_V145A2_TRIGGER_EXECUTE"] == "1"
let triggerConfirm = env["GENESIS_V145A2_TRIGGER_CONFIRM"] ?? ""
let triggerToken = "GENESIS_V145A2_TRIGGER_W3C_MODAL"

func emit(_ payload: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}

func jsonValue(_ value: Any?) -> Any {
    value ?? NSNull()
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

func labelFields(_ element: AXUIElement) -> [String] {
    [
        stringAttribute(element, kAXTitleAttribute),
        stringAttribute(element, kAXDescriptionAttribute),
        stringAttribute(element, kAXValueAttribute),
    ]
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    .filter { !$0.isEmpty }
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
var allItems: [QueueItem] = []
var triggerMatches: [[String: Any]] = []
var triggerElements: [AXUIElement] = []
var dialogItems: [QueueItem] = []
var queue = [QueueItem(element: selectedWindow, depth: 0, path: [])]

while !queue.isEmpty && visited < maxNodes {
    let item = queue.removeFirst()
    allItems.append(item)
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
        triggerElements.append(item.element)
    }

    let dialogLike = role == "AXDialog"
        || subrole == "AXApplicationDialog"
        || (role == "AXGroup" && dialogNeedles.contains { textLower.contains($0) } && actions.contains("AXCancel"))
    if dialogItems.count < maxMatches && dialogLike {
        dialogItems.append(item)
    }

    guard shouldDescend(role: role, depth: item.depth) else { continue }
    for (index, child) in children(of: item.element).enumerated() {
        queue.append(QueueItem(element: child, depth: item.depth + 1, path: item.path + [index]))
    }
}

let selectedTrigger = triggerElements.count == 1 ? triggerElements[0] : nil
let triggerMutationAuthorized = triggerExecute && triggerConfirm == triggerToken
let axMutationAttempted = triggerMutationAuthorized && selectedTrigger != nil
let triggerPressStatus: String
if axMutationAttempted, let selectedTrigger {
    let status = AXUIElementPerformAction(selectedTrigger, "AXPress" as CFString)
    triggerPressStatus = statusName(status)
} else if triggerExecute {
    triggerPressStatus = triggerConfirm == triggerToken ? "not_attempted_no_unique_trigger" : "not_attempted_missing_confirm"
} else {
    triggerPressStatus = "not_attempted"
}
if axMutationAttempted {
    usleep(250_000)
}

let dialogMatches = dialogItems.map { elementPayload($0.element, depth: $0.depth, path: $0.path) }
let selectedDialog = dialogItems.min { lhs, rhs in
    let lhsArea = rectAttribute(lhs.element, "AXFrame")?["area"] ?? Double.greatestFiniteMagnitude
    let rhsArea = rectAttribute(rhs.element, "AXFrame")?["area"] ?? Double.greatestFiniteMagnitude
    return lhsArea < rhsArea
}
let selectedDialogFrame = selectedDialog.flatMap { rectAttribute($0.element, "AXFrame") }
var candidatePayloads: [[String: Any]] = []
var legalCandidateCount = 0

if let selectedDialog, let selectedDialogFrame {
    for item in allItems {
        let role = stringAttribute(item.element, kAXRoleAttribute)
        guard roleWhitelist.contains(role) else { continue }
        let fields = labelFields(item.element)
        let label = haystack(item.element)
        let labelLower = label.lowercased()
        guard !labelLower.isEmpty else { continue }
        let frame = rectAttribute(item.element, "AXFrame")
        let center = frame.map { ["x": $0["center_x"] ?? 0, "y": $0["center_y"] ?? 0] }
        let insideDialog = isDescendantPath(item.path, of: selectedDialog.path)
            && containsPoint(selectedDialogFrame, center)
        guard insideDialog else { continue }
        let whitelistMatch = fields.contains { whitelist.contains($0) }
        let blacklistMatches = blacklist.filter { !labelLower.isEmpty && labelLower.contains($0) }
        let legal = whitelistMatch && blacklistMatches.isEmpty
        if legal {
            legalCandidateCount += 1
        }
        var payload = elementPayload(item.element, depth: item.depth, path: item.path)
        payload["label"] = label
        payload["label_fields"] = fields
        payload["inside_occluder"] = insideDialog
        payload["inside_occluder_tree"] = insideDialog
        payload["role_allowed"] = true
        payload["whitelist_match"] = whitelistMatch
        payload["blacklist_matches"] = blacklistMatches
        payload["legal_candidate"] = legal
        candidatePayloads.append(payload)
    }
}
let rejectedCandidateCount = candidatePayloads.filter { ($0["legal_candidate"] as? Bool) != true }.count
let safeToArm = !dialogMatches.isEmpty
    && legalCandidateCount == 1
    && candidatePayloads.count >= 2
    && rejectedCandidateCount >= 1

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
    "trigger_execute_requested": triggerExecute,
    "trigger_mutation_authorized": triggerMutationAuthorized,
    "trigger_press_status": triggerPressStatus,
    "public_obstacle_seen": !dialogMatches.isEmpty,
    "occluder_kind": dialogMatches.isEmpty ? "none" : "modal",
    "dialog_candidate_count": dialogMatches.count,
    "dialog_candidates": dialogMatches,
    "candidate_count": candidatePayloads.count,
    "legal_candidate_count": legalCandidateCount,
    "rejected_candidate_count": rejectedCandidateCount,
    "candidates": candidatePayloads,
    "safe_to_arm": safeToArm,
    "whitelist": Array(whitelist).sorted(),
    "blacklist": blacklist,
    "visited_count": visited,
    "posted": false,
    "physical_input_posted": false,
    "ax_mutation_attempted": axMutationAttempted,
])
