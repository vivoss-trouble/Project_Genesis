import AppKit
import ApplicationServices
import Foundation

let env = ProcessInfo.processInfo.environment
let bundleIdNeedle = env["GENESIS_V100_BROWSER_BUNDLE_ID"] ?? "com.apple.Safari"
let browserNameNeedle = (env["GENESIS_V100_BROWSER_APP"] ?? "Safari").lowercased()
let titleNeedle = (env["GENESIS_V100_WINDOW_TITLE"] ?? "The Rust Programming Language").lowercased()
let maxDepth = Int(env["GENESIS_V100_AX_MAX_DEPTH"] ?? "8") ?? 8
let maxNodes = Int(env["GENESIS_V100_AX_MAX_NODES"] ?? "800") ?? 800

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

func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
    let (status, value) = copyAttribute(element, attribute)
    guard status == .success, let bool = value as? Bool else { return nil }
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

func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> String {
    statusName(AXUIElementSetAttributeValue(element, attribute as CFString, value as CFTypeRef))
}

func elementSummary(_ element: AXUIElement, depth: Int, path: [Int]) -> [String: Any] {
    [
        "depth": depth,
        "path": path,
        "role": stringAttribute(element, kAXRoleAttribute),
        "subrole": stringAttribute(element, kAXSubroleAttribute),
        "title": stringAttribute(element, kAXTitleAttribute),
        "description": stringAttribute(element, kAXDescriptionAttribute),
    ]
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
        "event": "v100_ax_web_area_focus_probe",
        "status": "error",
        "error": "browser app not running",
        "accessibility_api_trusted": trusted,
        "posted": false,
        "physical_input_posted": false,
        "os_driver_active": false,
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
        "event": "v100_ax_web_area_focus_probe",
        "status": "error",
        "error": "browser window not found",
        "browser_bundle_id": app.bundleIdentifier ?? "",
        "browser_pid": app.processIdentifier,
        "accessibility_api_trusted": trusted,
        "window_count": windowList.count,
        "posted": false,
        "physical_input_posted": false,
        "os_driver_active": false,
    ])
    exit(1)
}

let selectedTitle = stringAttribute(selectedWindow, kAXTitleAttribute)
let activateResult = app.activate(options: [.activateAllWindows])
let setFrontmostStatus = setBool(appElement, kAXFrontmostAttribute, true)
let raiseStatus = statusName(AXUIElementPerformAction(selectedWindow, kAXRaiseAction as CFString))
let setFocusedWindowStatus = statusName(AXUIElementSetAttributeValue(
    appElement,
    kAXFocusedWindowAttribute as CFString,
    selectedWindow
))
let setMainStatus = setBool(selectedWindow, kAXMainAttribute, true)

struct QueueItem {
    let element: AXUIElement
    let depth: Int
    let path: [Int]
}

var queue = [QueueItem(element: selectedWindow, depth: 0, path: [])]
var visitedCount = 0
var roleCounts: [String: Int] = [:]
var webArea: QueueItem?
var webAreaCandidates: [[String: Any]] = []

while !queue.isEmpty && visitedCount < maxNodes {
    let item = queue.removeFirst()
    visitedCount += 1
    let role = stringAttribute(item.element, kAXRoleAttribute)
    roleCounts[role, default: 0] += 1

    if role == "AXWebArea" {
        if webArea == nil {
            webArea = item
        }
        if webAreaCandidates.count < 8 {
            webAreaCandidates.append(elementSummary(item.element, depth: item.depth, path: item.path))
        }
        continue
    }

    guard item.depth < maxDepth else { continue }
    let childElements = children(of: item.element)
    for (index, child) in childElements.enumerated() {
        queue.append(QueueItem(element: child, depth: item.depth + 1, path: item.path + [index]))
    }
}

var setFocusedElementStatus = "not_attempted"
var setWebAreaFocusedStatus = "not_attempted"
var webAreaFocusedAfter: Bool? = nil
var focusedRoleAfter = ""
var focusedTitleAfter = ""
var focusedDescriptionAfter = ""
var selectedWebArea: [String: Any] = [:]

if let webArea {
    selectedWebArea = elementSummary(webArea.element, depth: webArea.depth, path: webArea.path)
    setFocusedElementStatus = statusName(AXUIElementSetAttributeValue(
        appElement,
        kAXFocusedUIElementAttribute as CFString,
        webArea.element
    ))
    setWebAreaFocusedStatus = setBool(webArea.element, kAXFocusedAttribute, true)
    webAreaFocusedAfter = boolAttribute(webArea.element, kAXFocusedAttribute)

    let (_, focusedValue) = copyAttribute(appElement, kAXFocusedUIElementAttribute)
    if let focused = focusedValue {
        let focusedElement = unsafeBitCast(focused, to: AXUIElement.self)
        focusedRoleAfter = stringAttribute(focusedElement, kAXRoleAttribute)
        focusedTitleAfter = stringAttribute(focusedElement, kAXTitleAttribute)
        focusedDescriptionAfter = stringAttribute(focusedElement, kAXDescriptionAttribute)
    }
}

let webAreaFound = webArea != nil
let webAreaFocusAttempted = webAreaFound
let webAreaFocusSuccess = webAreaFound && (
    setFocusedElementStatus == "success"
    || setWebAreaFocusedStatus == "success"
    || focusedRoleAfter == "AXWebArea"
)

emit([
    "event": "v100_ax_web_area_focus_probe",
    "status": "ok",
    "accessibility_api_trusted": trusted,
    "browser_bundle_id": app.bundleIdentifier ?? "",
    "browser_localized_name": app.localizedName ?? "",
    "browser_pid": app.processIdentifier,
    "requested_window_title": titleNeedle,
    "selected_window_title": selectedTitle,
    "window_count": windowList.count,
    "nsworkspace_activate": activateResult,
    "set_frontmost_status": setFrontmostStatus,
    "raise_status": raiseStatus,
    "set_focused_window_status": setFocusedWindowStatus,
    "set_main_status": setMainStatus,
    "max_depth": maxDepth,
    "max_nodes": maxNodes,
    "visited_count": visitedCount,
    "role_counts": roleCounts,
    "web_area_found": webAreaFound,
    "web_area_focus_attempted": webAreaFocusAttempted,
    "web_area_focus_success": webAreaFocusSuccess,
    "selected_web_area": selectedWebArea,
    "web_area_candidates": webAreaCandidates,
    "set_focused_element_status": setFocusedElementStatus,
    "set_web_area_focused_status": setWebAreaFocusedStatus,
    "web_area_focused_after": webAreaFocusedAfter as Any,
    "focused_role_after": focusedRoleAfter,
    "focused_title_after": focusedTitleAfter,
    "focused_description_after": focusedDescriptionAfter,
    "posted": false,
    "physical_input_posted": false,
    "os_driver_active": false,
])
