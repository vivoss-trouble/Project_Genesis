import AppKit
import ApplicationServices
import Foundation

let env = ProcessInfo.processInfo.environment
let bundleIdNeedle = env["GENESIS_V103_BROWSER_BUNDLE_ID"] ?? "com.apple.Safari"
let browserNameNeedle = (env["GENESIS_V103_BROWSER_APP"] ?? "Safari").lowercased()
let titleNeedle = (env["GENESIS_V103_WINDOW_TITLE"] ?? "The Rust Programming Language").lowercased()
let targetNeedle = (env["GENESIS_V103_AX_TARGET_TITLE"] ?? "Final Project").lowercased()
let locateMaxDepth = Int(env["GENESIS_V103_AX_LOCATE_MAX_DEPTH"] ?? "8") ?? 8
let locateMaxNodes = Int(env["GENESIS_V103_AX_LOCATE_MAX_NODES"] ?? "900") ?? 900
let targetMaxDepth = Int(env["GENESIS_V103_TARGET_MAX_DEPTH"] ?? "10") ?? 10
let targetMaxNodes = Int(env["GENESIS_V103_TARGET_MAX_NODES"] ?? "2800") ?? 2800
let maxCandidates = Int(env["GENESIS_V103_MAX_CANDIDATES"] ?? "12") ?? 12
let execute = env["GENESIS_V103_AX_EXECUTE"] == "1"
let pointX = Double(env["GENESIS_V103_POINT_X"] ?? "")
let pointY = Double(env["GENESIS_V103_POINT_Y"] ?? "")

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

func copyParameterizedAttribute(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> (AXError, CFTypeRef?) {
    var value: CFTypeRef?
    let status = AXUIElementCopyParameterizedAttributeValue(
        element,
        attribute as CFString,
        parameter,
        &value
    )
    return (status, value)
}

func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String {
    let (status, value) = copyAttribute(element, attribute)
    guard status == .success, let string = value as? String else { return "" }
    return string
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
    ].joined(separator: " ").lowercased()
}

func shouldDescend(role: String, depth: Int) -> Bool {
    guard depth < targetMaxDepth else { return false }
    return [
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
        "AXHeading",
    ].contains(role)
}

struct QueueItem {
    let element: AXUIElement
    let depth: Int
    let path: [Int]
    let ancestors: [(element: AXUIElement, depth: Int, path: [Int])]
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
        "event": "v103_ax_scroll_to_visible_probe",
        "status": "error",
        "error": "browser app not running",
        "accessibility_api_trusted": trusted,
        "posted": false,
        "physical_input_posted": false,
        "os_driver_active": false,
        "ax_mutation_attempted": false,
    ])
    exit(1)
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)
let windowList = windows(of: appElement)
let selectedWindow = windowList.first { window in
    stringAttribute(window, kAXTitleAttribute).lowercased().contains(titleNeedle)
} ?? windowList.first

guard let selectedWindow else {
    emit([
        "event": "v103_ax_scroll_to_visible_probe",
        "status": "error",
        "error": "browser window not found",
        "accessibility_api_trusted": trusted,
        "posted": false,
        "physical_input_posted": false,
        "os_driver_active": false,
        "ax_mutation_attempted": false,
    ])
    exit(1)
}

func locateWebArea() -> (visited: Int, webArea: QueueItem?) {
    var queue = [QueueItem(element: selectedWindow, depth: 0, path: [], ancestors: [])]
    var visited = 0
    while !queue.isEmpty && visited < locateMaxNodes {
        let item = queue.removeFirst()
        visited += 1
        let role = stringAttribute(item.element, kAXRoleAttribute)
        if role == "AXWebArea" {
            return (visited, item)
        }
        guard item.depth < locateMaxDepth else { continue }
        let newAncestors = item.ancestors + [(item.element, item.depth, item.path)]
        for (index, child) in children(of: item.element).enumerated() {
            queue.append(QueueItem(
                element: child,
                depth: item.depth + 1,
                path: item.path + [index],
                ancestors: newAncestors
            ))
        }
    }
    return (visited, nil)
}

var locate = locateWebArea()
var axScanRetryUsed = false
if locate.webArea == nil {
    usleep(300_000)
    locate = locateWebArea()
    axScanRetryUsed = true
}

var markerBridge: [String: Any] = [
    "attempted": pointX != nil && pointY != nil,
    "text_marker_status": "not_attempted",
    "ui_element_status": "not_attempted",
]

if let webArea = locate.webArea, let x = pointX, let y = pointY {
    var point = CGPoint(x: x, y: y)
    let pointValue = AXValueCreate(.cgPoint, &point)
    if let pointValue {
        let (markerStatus, markerValue) = copyParameterizedAttribute(
            webArea.element,
            "AXTextMarkerForPosition",
            pointValue
        )
        markerBridge["text_marker_status"] = statusName(markerStatus)
        if markerStatus == .success, let markerValue {
            let (elementStatus, elementValue) = copyParameterizedAttribute(
                webArea.element,
                "AXUIElementForTextMarker",
                markerValue
            )
            markerBridge["ui_element_status"] = statusName(elementStatus)
            if elementStatus == .success, let elementValue {
                let element = unsafeBitCast(elementValue, to: AXUIElement.self)
                markerBridge["resolved_element"] = elementPayload(element, depth: -1, path: [])
            }
        }
    }
}

var visitedTargets = 0
var candidates: [[String: Any]] = []
var selectedTarget: QueueItem?

if let webArea = locate.webArea {
    var queue = [QueueItem(element: webArea.element, depth: 0, path: [], ancestors: [])]
    while !queue.isEmpty && visitedTargets < targetMaxNodes {
        let item = queue.removeFirst()
        visitedTargets += 1
        let role = stringAttribute(item.element, kAXRoleAttribute)
        if haystack(item.element).contains(targetNeedle) {
            if candidates.count < maxCandidates {
                candidates.append(elementPayload(item.element, depth: item.depth, path: item.path))
            }
            if selectedTarget == nil {
                selectedTarget = item
            }
        }
        guard shouldDescend(role: role, depth: item.depth) else { continue }
        let newAncestors = item.ancestors + [(item.element, item.depth, item.path)]
        for (index, child) in children(of: item.element).enumerated() {
            queue.append(QueueItem(
                element: child,
                depth: item.depth + 1,
                path: item.path + [index],
                ancestors: newAncestors
            ))
        }
    }
}

let targetActions = selectedTarget.map { actionNames($0.element) } ?? []
let scrollToVisibleAvailable = targetActions.contains("AXScrollToVisible")
let mutationAttempted = execute && selectedTarget != nil && scrollToVisibleAvailable
var scrollToVisibleStatus = "not_attempted"
var targetFrameAfter: [String: Double]? = nil

if mutationAttempted, let selectedTarget {
    scrollToVisibleStatus = statusName(AXUIElementPerformAction(
        selectedTarget.element,
        "AXScrollToVisible" as CFString
    ))
    usleep(250_000)
    targetFrameAfter = rectAttribute(selectedTarget.element, "AXFrame")
}

emit([
    "event": "v103_ax_scroll_to_visible_probe",
    "status": "ok",
    "accessibility_api_trusted": trusted,
    "browser_bundle_id": app.bundleIdentifier ?? "",
    "browser_localized_name": app.localizedName ?? "",
    "browser_pid": app.processIdentifier,
    "selected_window_title": stringAttribute(selectedWindow, kAXTitleAttribute),
    "requested_window_title": titleNeedle,
    "requested_target_title": targetNeedle,
    "locate_visited_count": locate.visited,
    "ax_scan_retry_used": axScanRetryUsed,
    "web_area_found": locate.webArea != nil,
    "web_area_path": locate.webArea?.path ?? [],
    "web_area_actions": locate.webArea.map { actionNames($0.element) } ?? [],
    "marker_bridge": markerBridge,
    "target_search_visited_count": visitedTargets,
    "target_found": selectedTarget != nil,
    "target_candidates": candidates,
    "selected_target": selectedTarget.map { elementPayload($0.element, depth: $0.depth, path: $0.path) } ?? [:],
    "selected_target_actions": targetActions,
    "scroll_to_visible_available": scrollToVisibleAvailable,
    "execute_requested": execute,
    "ax_mutation_attempted": mutationAttempted,
    "scroll_to_visible_status": scrollToVisibleStatus,
    "target_frame_after_action": jsonValue(targetFrameAfter),
    "posted": false,
    "physical_input_posted": false,
    "os_driver_active": false,
])
