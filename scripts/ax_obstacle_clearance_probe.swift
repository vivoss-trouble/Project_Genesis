import AppKit
import ApplicationServices
import Foundation

let env = ProcessInfo.processInfo.environment
let bundleIdNeedle = env["GENESIS_V130_BROWSER_BUNDLE_ID"] ?? "com.apple.Safari"
let browserNameNeedle = (env["GENESIS_V130_BROWSER_APP"] ?? "Safari").lowercased()
let titleNeedle = (env["GENESIS_V130_WINDOW_TITLE"] ?? "Genesis v13.0 Obstacle Fixture").lowercased()
let targetNeedle = (env["GENESIS_V130_TARGET_TITLE"] ?? "Next chapter").lowercased()
let publicRecon = env["GENESIS_V130_PUBLIC_RECON"] == "1"
let maxDepth = Int(env["GENESIS_V130_AX_MAX_DEPTH"] ?? "12") ?? 12
let maxNodes = Int(env["GENESIS_V130_AX_MAX_NODES"] ?? "2400") ?? 2400
let whitelist = Set((env["GENESIS_V130_WHITELIST"] ?? "close,dismiss,not now,reject all,decline")
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
let blacklist = (env["GENESIS_V130_BLACKLIST"] ?? "accept,subscribe,continue,agree")
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
let roleWhitelist = Set((env["GENESIS_V130_ROLE_WHITELIST"] ?? "AXButton,AXLink")
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })

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

func containsPoint(_ rect: [String: Double]?, _ point: [String: Double]?) -> Bool {
    guard let rect, let point, let x = point["x"], let y = point["y"] else { return false }
    return x >= (rect["x"] ?? 0)
        && x <= (rect["x"] ?? 0) + (rect["width"] ?? 0)
        && y >= (rect["y"] ?? 0)
        && y <= (rect["y"] ?? 0) + (rect["height"] ?? 0)
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
        "event": "v130_obstacle_clearance_probe",
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
let windowTitles = windowList.map { stringAttribute($0, kAXTitleAttribute) }
guard !matchingWindows.isEmpty else {
    emit([
        "event": "v130_obstacle_clearance_probe",
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
let selectedWindow = matchingWindows.first { window in
    boolAttribute(window, kAXMainAttribute) || boolAttribute(window, kAXFocusedAttribute)
} ?? matchingWindows.first

guard let selectedWindow else {
    emit([
        "event": "v130_obstacle_clearance_probe",
        "status": "error",
        "error": "browser window not found",
        "accessibility_api_trusted": trusted,
        "posted": false,
        "physical_input_posted": false,
        "ax_mutation_attempted": false,
    ])
    exit(1)
}

var visited = 0
var allItems: [QueueItem] = []
var targetItem: QueueItem?
var queue = [QueueItem(element: selectedWindow, depth: 0, path: [])]

while !queue.isEmpty && visited < maxNodes {
    let item = queue.removeFirst()
    allItems.append(item)
    visited += 1

    if targetItem == nil && haystack(item.element).lowercased().contains(targetNeedle) {
        targetItem = item
    }

    let role = stringAttribute(item.element, kAXRoleAttribute)
    guard shouldDescend(role: role, depth: item.depth) else { continue }
    for (index, child) in children(of: item.element).enumerated() {
        queue.append(QueueItem(element: child, depth: item.depth + 1, path: item.path + [index]))
    }
}

let targetFrame = targetItem.flatMap { rectAttribute($0.element, "AXFrame") }
let targetPoint = targetFrame.map {
    ["x": $0["center_x"] ?? 0, "y": $0["center_y"] ?? 0]
}

let containerRoles = Set(["AXGroup", "AXOpaqueProviderGroup", "AXScrollArea", "AXWebArea", "AXDialog"])
let modalNeedles = ["modal", "dialog", "cookie", "newsletter"]
let iframeNeedles = ["iframe obstacle", "iframe visual obstacle"]
func isOccluderLike(_ item: QueueItem) -> Bool {
    let role = stringAttribute(item.element, kAXRoleAttribute)
    let subrole = stringAttribute(item.element, kAXSubroleAttribute)
    if role == "AXDialog" || subrole == "AXApplicationDialog" {
        return true
    }
    let text = haystack(item.element).lowercased()
    return modalNeedles.contains { text.contains($0) }
}

func isIframeOccluderLike(_ item: QueueItem) -> Bool {
    let role = stringAttribute(item.element, kAXRoleAttribute)
    let text = haystack(item.element).lowercased()
    return (role == "AXWebArea" || role == "AXGroup")
        && iframeNeedles.contains { text.contains($0) }
}

let targetContainingContainers = allItems.filter { item in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    guard containerRoles.contains(role) else { return false }
    return containsPoint(rectAttribute(item.element, "AXFrame"), targetPoint)
}
let targetContainingContainerPayloads = targetContainingContainers.map {
    elementPayload($0.element, depth: $0.depth, path: $0.path)
}
let publicReconContainers = allItems.filter { item in
    let role = stringAttribute(item.element, kAXRoleAttribute)
    guard containerRoles.contains(role) else { return false }
    return rectAttribute(item.element, "AXFrame") != nil
}
let occluderSearchContainers = publicRecon ? publicReconContainers : targetContainingContainers

let modalOccluderItem = occluderSearchContainers
    .filter(isOccluderLike)
    .min { lhs, rhs in
        let lhsArea = rectAttribute(lhs.element, "AXFrame")?["area"] ?? Double.greatestFiniteMagnitude
        let rhsArea = rectAttribute(rhs.element, "AXFrame")?["area"] ?? Double.greatestFiniteMagnitude
        return lhsArea < rhsArea
    }
let iframeOccluderItem = occluderSearchContainers
    .filter(isIframeOccluderLike)
    .min { lhs, rhs in
        let lhsArea = rectAttribute(lhs.element, "AXFrame")?["area"] ?? Double.greatestFiniteMagnitude
        let rhsArea = rectAttribute(rhs.element, "AXFrame")?["area"] ?? Double.greatestFiniteMagnitude
        return lhsArea < rhsArea
    }
let occluderItem = modalOccluderItem ?? iframeOccluderItem
let occluderKind = modalOccluderItem != nil ? "modal" : (iframeOccluderItem != nil ? "iframe" : "none")
let occluderFrame = occluderItem.flatMap { rectAttribute($0.element, "AXFrame") }
let occlusionClear = publicRecon ? occluderItem == nil : targetItem != nil && occluderItem == nil

var candidatePayloads: [[String: Any]] = []
var legalItems: [QueueItem] = []

if let occluderFrame, let occluderItem {
    for item in allItems {
        let role = stringAttribute(item.element, kAXRoleAttribute)
        let label = haystack(item.element)
        let labelLower = label.lowercased()
        let fields = labelFields(item.element)
        let frame = rectAttribute(item.element, "AXFrame")
        let center = frame.map { ["x": $0["center_x"] ?? 0, "y": $0["center_y"] ?? 0] }
        let insideOccluder = containsPoint(occluderFrame, center)
        let insideOccluderTree = isDescendantPath(item.path, of: occluderItem.path)
        let roleAllowed = roleWhitelist.contains(role)
        let whitelistMatch = fields.contains { whitelist.contains($0) }
        let blacklistMatches = blacklist.filter { !labelLower.isEmpty && labelLower.contains($0) }
        let legal = insideOccluderTree && insideOccluder && roleAllowed && whitelistMatch && blacklistMatches.isEmpty

        guard roleAllowed && insideOccluderTree && insideOccluder && !labelLower.isEmpty else { continue }

        var payload = elementPayload(item.element, depth: item.depth, path: item.path)
        payload["label"] = label
        payload["label_fields"] = fields
        payload["inside_occluder"] = insideOccluder
        payload["inside_occluder_tree"] = insideOccluderTree
        payload["role_allowed"] = roleAllowed
        payload["whitelist_match"] = whitelistMatch
        payload["blacklist_matches"] = blacklistMatches
        payload["legal_candidate"] = legal
        candidatePayloads.append(payload)

        if legal {
            legalItems.append(item)
        }
    }
}

let selectedClearance = legalItems.count == 1 ? legalItems[0] : nil
let selectedFrame = selectedClearance.flatMap { rectAttribute($0.element, "AXFrame") }
let clearancePoint = selectedFrame.map {
    ["x": $0["center_x"] ?? 0, "y": $0["center_y"] ?? 0]
}
let rejectedCount = candidatePayloads.filter { ($0["legal_candidate"] as? Bool) != true }.count
let stopReason: String
if selectedClearance == nil && !occlusionClear {
    stopReason = occluderKind == "iframe" ? "iframe_occluder_unresolved" : "obstacle_unresolved"
} else {
    stopReason = "candidate_resolved"
}

emit([
    "event": "v130_obstacle_clearance_probe",
    "status": "ok",
    "accessibility_api_trusted": trusted,
    "browser_bundle_id": app.bundleIdentifier ?? "",
    "browser_localized_name": app.localizedName ?? "",
    "browser_pid": app.processIdentifier,
    "selected_window_title": stringAttribute(selectedWindow, kAXTitleAttribute),
    "window_frame": jsonValue(rectAttribute(selectedWindow, "AXFrame")),
    "target_found": targetItem != nil,
    "public_recon": publicRecon,
    "target": targetItem.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "target_point": jsonValue(targetPoint),
    "occlusion_clear": occlusionClear,
    "occluder_found": occluderItem != nil,
    "occluder_kind": occluderKind,
    "occluder": occluderItem.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "occluder_frame": jsonValue(occluderFrame),
    "target_containing_container_count": targetContainingContainers.count,
    "target_containing_containers": targetContainingContainerPayloads,
    "candidate_count": candidatePayloads.count,
    "legal_candidate_count": legalItems.count,
    "rejected_candidate_count": rejectedCount,
    "candidates": candidatePayloads,
    "selected_clearance": selectedClearance.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "clearance_point": jsonValue(clearancePoint),
    "clearance_resolved": selectedClearance != nil,
    "stop_reason": stopReason,
    "whitelist": Array(whitelist).sorted(),
    "blacklist": blacklist,
    "role_whitelist": Array(roleWhitelist).sorted(),
    "visited_count": visited,
    "posted": false,
    "physical_input_posted": false,
    "ax_mutation_attempted": false,
])
