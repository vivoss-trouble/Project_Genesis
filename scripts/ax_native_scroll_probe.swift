import AppKit
import ApplicationServices
import Foundation

let env = ProcessInfo.processInfo.environment
let bundleIdNeedle = env["GENESIS_V101_BROWSER_BUNDLE_ID"] ?? "com.apple.Safari"
let browserNameNeedle = (env["GENESIS_V101_BROWSER_APP"] ?? "Safari").lowercased()
let titleNeedle = (env["GENESIS_V101_WINDOW_TITLE"] ?? "The Rust Programming Language").lowercased()
let maxDepth = Int(env["GENESIS_V101_AX_MAX_DEPTH"] ?? "8") ?? 8
let maxNodes = Int(env["GENESIS_V101_AX_MAX_NODES"] ?? "900") ?? 900
let execute = env["GENESIS_V101_AX_EXECUTE"] == "1"
let requestedPrimitive = env["GENESIS_V101_AX_PRIMITIVE"] ?? "auto"
let requestedAction = env["GENESIS_V101_AX_ACTION"] ?? "AXScrollDown"
let requestedValueDelta = Double(env["GENESIS_V101_AX_VALUE_DELTA"] ?? "0.12") ?? 0.12

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

func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
    let (status, value) = copyAttribute(element, attribute)
    guard status == .success, let bool = value as? Bool else { return nil }
    return bool
}

func numberAttribute(_ element: AXUIElement, _ attribute: String) -> Double? {
    let (status, value) = copyAttribute(element, attribute)
    guard status == .success else { return nil }
    if let number = value as? NSNumber {
        return number.doubleValue
    }
    return nil
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

func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool? {
    var settable = DarwinBoolean(false)
    let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
    guard status == .success else { return nil }
    return settable.boolValue
}

func actionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    let status = AXUIElementCopyActionNames(element, &names)
    guard status == .success, let strings = names as? [String] else { return [] }
    return strings.sorted()
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

func scrollbarSummary(_ element: AXUIElement, depth: Int, path: [Int]) -> [String: Any] {
    var payload = elementSummary(element, depth: depth, path: path)
    payload["orientation"] = stringAttribute(element, kAXOrientationAttribute)
    payload["value"] = jsonValue(numberAttribute(element, kAXValueAttribute))
    payload["min_value"] = jsonValue(numberAttribute(element, kAXMinValueAttribute))
    payload["max_value"] = jsonValue(numberAttribute(element, kAXMaxValueAttribute))
    payload["value_settable"] = jsonValue(isSettable(element, kAXValueAttribute))
    payload["actions"] = actionNames(element)
    return payload
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
        "event": "v101_ax_native_scroll_probe",
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
        "event": "v101_ax_native_scroll_probe",
        "status": "error",
        "error": "browser window not found",
        "browser_bundle_id": app.bundleIdentifier ?? "",
        "browser_pid": app.processIdentifier,
        "accessibility_api_trusted": trusted,
        "window_count": windowList.count,
        "posted": false,
        "physical_input_posted": false,
        "os_driver_active": false,
        "ax_mutation_attempted": false,
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

func scanSelectedWindow() -> (
    visitedCount: Int,
    roleCounts: [String: Int],
    webArea: QueueItem?,
    nearestScrollAncestor: QueueItem?,
    scrollAreaCandidates: [[String: Any]],
    scrollbarCandidates: [[String: Any]],
    firstVerticalScrollbar: QueueItem?
) {
    var queue = [QueueItem(element: selectedWindow, depth: 0, path: [], ancestors: [])]
    var visitedCount = 0
    var roleCounts: [String: Int] = [:]
    var webArea: QueueItem?
    var nearestScrollAncestor: QueueItem?
    var scrollAreaCandidates: [[String: Any]] = []
    var scrollbarCandidates: [[String: Any]] = []
    var firstVerticalScrollbar: QueueItem?

    while !queue.isEmpty && visitedCount < maxNodes {
        let item = queue.removeFirst()
        visitedCount += 1
        let role = stringAttribute(item.element, kAXRoleAttribute)
        roleCounts[role, default: 0] += 1

        if role == "AXWebArea" {
            if webArea == nil {
                webArea = item
                if let ancestor = item.ancestors.reversed().first(where: {
                    stringAttribute($0.element, kAXRoleAttribute) == "AXScrollArea"
                }) {
                    nearestScrollAncestor = QueueItem(
                        element: ancestor.element,
                        depth: ancestor.depth,
                        path: ancestor.path,
                        ancestors: []
                    )
                }
            }
            // The DOM below AXWebArea can be enormous. v10.1 probes the native
            // control surface, not the page semantic tree.
            continue
        }

        if role == "AXScrollArea" && scrollAreaCandidates.count < 12 {
            var summary = elementSummary(item.element, depth: item.depth, path: item.path)
            summary["actions"] = actionNames(item.element)
            scrollAreaCandidates.append(summary)
        }

        if role == "AXScrollBar" {
            let orientation = stringAttribute(item.element, kAXOrientationAttribute)
            if scrollbarCandidates.count < 12 {
                scrollbarCandidates.append(scrollbarSummary(item.element, depth: item.depth, path: item.path))
            }
            if firstVerticalScrollbar == nil && orientation == kAXVerticalOrientationValue as String {
                firstVerticalScrollbar = item
            }
        }

        guard item.depth < maxDepth else { continue }
        let childElements = children(of: item.element)
        let newAncestors = item.ancestors + [(item.element, item.depth, item.path)]
        for (index, child) in childElements.enumerated() {
            queue.append(QueueItem(
                element: child,
                depth: item.depth + 1,
                path: item.path + [index],
                ancestors: newAncestors
            ))
        }
    }

    return (
        visitedCount,
        roleCounts,
        webArea,
        nearestScrollAncestor,
        scrollAreaCandidates,
        scrollbarCandidates,
        firstVerticalScrollbar
    )
}

var scan = scanSelectedWindow()
var axScanRetryUsed = false
if scan.webArea == nil {
    usleep(300_000)
    _ = AXUIElementPerformAction(selectedWindow, kAXRaiseAction as CFString)
    scan = scanSelectedWindow()
    axScanRetryUsed = true
}

let visitedCount = scan.visitedCount
let roleCounts = scan.roleCounts
let webArea = scan.webArea
let nearestScrollAncestor = scan.nearestScrollAncestor
let scrollAreaCandidates = scan.scrollAreaCandidates
let scrollbarCandidates = scan.scrollbarCandidates
let firstVerticalScrollbar = scan.firstVerticalScrollbar

var webAreaActions: [String] = []
var scrollAreaActions: [String] = []
var selectedWebArea: [String: Any] = [:]
var selectedScrollArea: [String: Any] = [:]
var selectedScrollbar: [String: Any] = [:]
var selectedPrimitive = "none"
var selectedActionTarget = "none"
var actionStatus = "not_attempted"
var scrollbarSetStatus = "not_attempted"
var scrollbarOldValue: Double? = nil
var scrollbarNewValue: Double? = nil
var scrollbarMinValue: Double? = nil
var scrollbarMaxValue: Double? = nil
var scrollbarValueSettable: Bool? = nil

if let webArea {
    selectedWebArea = elementSummary(webArea.element, depth: webArea.depth, path: webArea.path)
    webAreaActions = actionNames(webArea.element)
}

if let nearestScrollAncestor {
    selectedScrollArea = elementSummary(
        nearestScrollAncestor.element,
        depth: nearestScrollAncestor.depth,
        path: nearestScrollAncestor.path
    )
    scrollAreaActions = actionNames(nearestScrollAncestor.element)
}

if let firstVerticalScrollbar {
    selectedScrollbar = scrollbarSummary(
        firstVerticalScrollbar.element,
        depth: firstVerticalScrollbar.depth,
        path: firstVerticalScrollbar.path
    )
    scrollbarOldValue = numberAttribute(firstVerticalScrollbar.element, kAXValueAttribute)
    scrollbarMinValue = numberAttribute(firstVerticalScrollbar.element, kAXMinValueAttribute)
    scrollbarMaxValue = numberAttribute(firstVerticalScrollbar.element, kAXMaxValueAttribute)
    scrollbarValueSettable = isSettable(firstVerticalScrollbar.element, kAXValueAttribute)
}

let actionOnWebAreaAvailable = webAreaActions.contains(requestedAction)
let actionOnScrollAreaAvailable = scrollAreaActions.contains(requestedAction)
let scrollbarWriteAvailable = firstVerticalScrollbar != nil && scrollbarValueSettable == true && scrollbarOldValue != nil

if requestedPrimitive == "action" || (requestedPrimitive == "auto" && (actionOnWebAreaAvailable || actionOnScrollAreaAvailable)) {
    selectedPrimitive = "action"
    if actionOnWebAreaAvailable {
        selectedActionTarget = "web_area"
    } else if actionOnScrollAreaAvailable {
        selectedActionTarget = "scroll_area"
    }
} else if requestedPrimitive == "scrollbar_value" || (requestedPrimitive == "auto" && scrollbarWriteAvailable) {
    selectedPrimitive = "scrollbar_value"
    selectedActionTarget = "vertical_scrollbar"
}

let mutationAttempted = execute && selectedPrimitive != "none"

if execute {
    if selectedPrimitive == "action" {
        if selectedActionTarget == "web_area", let webArea {
            actionStatus = statusName(AXUIElementPerformAction(webArea.element, requestedAction as CFString))
        } else if selectedActionTarget == "scroll_area", let nearestScrollAncestor {
            actionStatus = statusName(AXUIElementPerformAction(nearestScrollAncestor.element, requestedAction as CFString))
        }
    } else if selectedPrimitive == "scrollbar_value", let firstVerticalScrollbar, let oldValue = scrollbarOldValue {
        let minValue = scrollbarMinValue ?? 0.0
        let maxValue = scrollbarMaxValue ?? 1.0
        let proposed = min(max(oldValue + requestedValueDelta, minValue), maxValue)
        scrollbarNewValue = proposed
        scrollbarSetStatus = statusName(AXUIElementSetAttributeValue(
            firstVerticalScrollbar.element,
            kAXValueAttribute as CFString,
            NSNumber(value: proposed)
        ))
    }
}

emit([
    "event": "v101_ax_native_scroll_probe",
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
    "ax_scan_retry_used": axScanRetryUsed,
    "role_counts": roleCounts,
    "web_area_found": webArea != nil,
    "selected_web_area": selectedWebArea,
    "web_area_actions": webAreaActions,
    "scroll_area_found": nearestScrollAncestor != nil,
    "selected_scroll_area": selectedScrollArea,
    "scroll_area_actions": scrollAreaActions,
    "scroll_area_candidates": scrollAreaCandidates,
    "vertical_scrollbar_found": firstVerticalScrollbar != nil,
    "selected_vertical_scrollbar": selectedScrollbar,
    "vertical_scrollbar_candidates": scrollbarCandidates,
    "vertical_scrollbar_value": jsonValue(scrollbarOldValue),
    "vertical_scrollbar_min_value": jsonValue(scrollbarMinValue),
    "vertical_scrollbar_max_value": jsonValue(scrollbarMaxValue),
    "vertical_scrollbar_value_settable": jsonValue(scrollbarValueSettable),
    "requested_primitive": requestedPrimitive,
    "requested_action": requestedAction,
    "requested_value_delta": requestedValueDelta,
    "action_on_web_area_available": actionOnWebAreaAvailable,
    "action_on_scroll_area_available": actionOnScrollAreaAvailable,
    "scrollbar_write_available": scrollbarWriteAvailable,
    "selected_primitive": selectedPrimitive,
    "selected_action_target": selectedActionTarget,
    "execute_requested": execute,
    "ax_mutation_attempted": mutationAttempted,
    "perform_action_status": actionStatus,
    "scrollbar_set_status": scrollbarSetStatus,
    "scrollbar_old_value": jsonValue(scrollbarOldValue),
    "scrollbar_new_value": jsonValue(scrollbarNewValue),
    "posted": false,
    "physical_input_posted": false,
    "os_driver_active": false,
])
