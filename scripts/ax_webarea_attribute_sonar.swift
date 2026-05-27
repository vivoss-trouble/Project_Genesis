import AppKit
import ApplicationServices
import Foundation

let env = ProcessInfo.processInfo.environment
let bundleIdNeedle = env["GENESIS_V102_BROWSER_BUNDLE_ID"] ?? "com.apple.Safari"
let browserNameNeedle = (env["GENESIS_V102_BROWSER_APP"] ?? "Safari").lowercased()
let titleNeedle = (env["GENESIS_V102_WINDOW_TITLE"] ?? "The Rust Programming Language").lowercased()
let locateMaxDepth = Int(env["GENESIS_V102_AX_LOCATE_MAX_DEPTH"] ?? "8") ?? 8
let locateMaxNodes = Int(env["GENESIS_V102_AX_LOCATE_MAX_NODES"] ?? "900") ?? 900
let sonarMaxDepth = Int(env["GENESIS_V102_SONAR_MAX_DEPTH"] ?? "4") ?? 4
let sonarMaxNodes = Int(env["GENESIS_V102_SONAR_MAX_NODES"] ?? "420") ?? 420
let maxRecordedNodes = Int(env["GENESIS_V102_MAX_RECORDED_NODES"] ?? "12") ?? 12

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

func attributeNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    let status = AXUIElementCopyAttributeNames(element, &names)
    guard status == .success, let strings = names as? [String] else { return [] }
    return strings.sorted()
}

func parameterizedAttributeNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    let status = AXUIElementCopyParameterizedAttributeNames(element, &names)
    guard status == .success, let strings = names as? [String] else { return [] }
    return strings.sorted()
}

func jsonValue(_ value: Any?) -> Any {
    value ?? NSNull()
}

func scalarSample(_ element: AXUIElement, attributes: [String]) -> [String: Any] {
    var payload: [String: Any] = [:]
    let scalarAttributes = [
        kAXRoleAttribute,
        kAXSubroleAttribute,
        kAXTitleAttribute,
        kAXDescriptionAttribute,
        kAXOrientationAttribute,
        kAXValueAttribute,
        kAXMinValueAttribute,
        kAXMaxValueAttribute,
    ]
    for attribute in scalarAttributes where attributes.contains(attribute) {
        let (status, value) = copyAttribute(element, attribute)
        guard status == .success, let value else { continue }
        if let string = value as? String {
            payload[attribute] = string
        } else if let number = value as? NSNumber {
            payload[attribute] = number
        } else if let bool = value as? Bool {
            payload[attribute] = bool
        }
    }
    return payload
}

func hasNeedle(_ values: [String], needles: [String]) -> Bool {
    for value in values {
        let lower = value.lowercased()
        if needles.contains(where: { lower.contains($0) }) {
            return true
        }
    }
    return false
}

func shouldDescend(role: String, depth: Int) -> Bool {
    if depth >= sonarMaxDepth {
        return false
    }
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
    ].contains(role)
}

func nodePayload(
    element: AXUIElement,
    depth: Int,
    path: [Int],
    attributes: [String],
    parameterizedAttributes: [String],
    actions: [String]
) -> [String: Any] {
    [
        "depth": depth,
        "path": path,
        "role": stringAttribute(element, kAXRoleAttribute),
        "subrole": stringAttribute(element, kAXSubroleAttribute),
        "title": stringAttribute(element, kAXTitleAttribute),
        "description": stringAttribute(element, kAXDescriptionAttribute),
        "attribute_names": attributes,
        "parameterized_attribute_names": parameterizedAttributes,
        "actions": actions,
        "scalar_sample": scalarSample(element, attributes: attributes),
        "child_count": children(of: element).count,
    ]
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
        "event": "v102_ax_webarea_attribute_sonar",
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
        "event": "v102_ax_webarea_attribute_sonar",
        "status": "error",
        "error": "browser window not found",
        "accessibility_api_trusted": trusted,
        "browser_bundle_id": app.bundleIdentifier ?? "",
        "browser_pid": app.processIdentifier,
        "window_count": windowList.count,
        "posted": false,
        "physical_input_posted": false,
        "os_driver_active": false,
        "ax_mutation_attempted": false,
    ])
    exit(1)
}

func locateWebArea() -> (
    visitedCount: Int,
    roleCounts: [String: Int],
    webArea: QueueItem?,
    nearestScrollAncestor: QueueItem?,
    scrollAreaCandidates: [[String: Any]]
) {
    var queue = [QueueItem(element: selectedWindow, depth: 0, path: [], ancestors: [])]
    var visitedCount = 0
    var roleCounts: [String: Int] = [:]
    var webArea: QueueItem?
    var nearestScrollAncestor: QueueItem?
    var scrollAreaCandidates: [[String: Any]] = []

    while !queue.isEmpty && visitedCount < locateMaxNodes {
        let item = queue.removeFirst()
        visitedCount += 1
        let role = stringAttribute(item.element, kAXRoleAttribute)
        roleCounts[role, default: 0] += 1

        if role == "AXScrollArea" && scrollAreaCandidates.count < maxRecordedNodes {
            let attrs = attributeNames(item.element)
            scrollAreaCandidates.append(nodePayload(
                element: item.element,
                depth: item.depth,
                path: item.path,
                attributes: attrs,
                parameterizedAttributes: parameterizedAttributeNames(item.element),
                actions: actionNames(item.element)
            ))
        }

        if role == "AXWebArea" {
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
            break
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

    return (visitedCount, roleCounts, webArea, nearestScrollAncestor, scrollAreaCandidates)
}

var locate = locateWebArea()
var axScanRetryUsed = false
if locate.webArea == nil {
    usleep(300_000)
    locate = locateWebArea()
    axScanRetryUsed = true
}

var sonarVisitedCount = 0
var sonarRoleCounts: [String: Int] = [:]
var recordedNodes: [[String: Any]] = []
var scrollSuspects: [[String: Any]] = []
var parameterizedSuspects: [[String: Any]] = []
var valueSuspects: [[String: Any]] = []
var allAttributeNames = Set<String>()
var allParameterizedAttributeNames = Set<String>()
var allActionNames = Set<String>()

if let webArea = locate.webArea {
    var queue = [QueueItem(element: webArea.element, depth: 0, path: [], ancestors: [])]
    while !queue.isEmpty && sonarVisitedCount < sonarMaxNodes {
        let item = queue.removeFirst()
        sonarVisitedCount += 1
        let role = stringAttribute(item.element, kAXRoleAttribute)
        let attrs = attributeNames(item.element)
        let params = parameterizedAttributeNames(item.element)
        let actions = actionNames(item.element)
        sonarRoleCounts[role, default: 0] += 1
        allAttributeNames.formUnion(attrs)
        allParameterizedAttributeNames.formUnion(params)
        allActionNames.formUnion(actions)

        let payload = nodePayload(
            element: item.element,
            depth: item.depth,
            path: item.path,
            attributes: attrs,
            parameterizedAttributes: params,
            actions: actions
        )
        if recordedNodes.count < maxRecordedNodes {
            recordedNodes.append(payload)
        }

        let scrollNeedles = ["scroll", "visible", "value", "range", "position"]
        let isScrollSuspect = role.lowercased().contains("scroll")
            || hasNeedle(attrs, needles: scrollNeedles)
            || hasNeedle(params, needles: scrollNeedles)
            || hasNeedle(actions, needles: scrollNeedles)
        if isScrollSuspect && scrollSuspects.count < maxRecordedNodes {
            scrollSuspects.append(payload)
        }
        if !params.isEmpty && parameterizedSuspects.count < maxRecordedNodes {
            parameterizedSuspects.append(payload)
        }
        if attrs.contains(kAXValueAttribute) && valueSuspects.count < maxRecordedNodes {
            valueSuspects.append(payload)
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

let selectedTitle = stringAttribute(selectedWindow, kAXTitleAttribute)
let webAreaAttrs = locate.webArea.map { attributeNames($0.element) } ?? []
let webAreaParams = locate.webArea.map { parameterizedAttributeNames($0.element) } ?? []
let webAreaActions = locate.webArea.map { actionNames($0.element) } ?? []
let scrollAncestorAttrs = locate.nearestScrollAncestor.map { attributeNames($0.element) } ?? []
let scrollAncestorParams = locate.nearestScrollAncestor.map { parameterizedAttributeNames($0.element) } ?? []
let scrollAncestorActions = locate.nearestScrollAncestor.map { actionNames($0.element) } ?? []

emit([
    "event": "v102_ax_webarea_attribute_sonar",
    "status": "ok",
    "accessibility_api_trusted": trusted,
    "browser_bundle_id": app.bundleIdentifier ?? "",
    "browser_localized_name": app.localizedName ?? "",
    "browser_pid": app.processIdentifier,
    "requested_window_title": titleNeedle,
    "selected_window_title": selectedTitle,
    "window_count": windowList.count,
    "locate_max_depth": locateMaxDepth,
    "locate_max_nodes": locateMaxNodes,
    "locate_visited_count": locate.visitedCount,
    "locate_role_counts": locate.roleCounts,
    "ax_scan_retry_used": axScanRetryUsed,
    "web_area_found": locate.webArea != nil,
    "web_area_path": locate.webArea?.path ?? [],
    "web_area_depth": jsonValue(locate.webArea?.depth),
    "web_area_attribute_names": webAreaAttrs,
    "web_area_parameterized_attribute_names": webAreaParams,
    "web_area_actions": webAreaActions,
    "nearest_scroll_ancestor_found": locate.nearestScrollAncestor != nil,
    "nearest_scroll_ancestor_path": locate.nearestScrollAncestor?.path ?? [],
    "nearest_scroll_ancestor_depth": jsonValue(locate.nearestScrollAncestor?.depth),
    "nearest_scroll_ancestor_attribute_names": scrollAncestorAttrs,
    "nearest_scroll_ancestor_parameterized_attribute_names": scrollAncestorParams,
    "nearest_scroll_ancestor_actions": scrollAncestorActions,
    "locate_scroll_area_candidates": locate.scrollAreaCandidates,
    "sonar_max_depth": sonarMaxDepth,
    "sonar_max_nodes": sonarMaxNodes,
    "sonar_visited_count": sonarVisitedCount,
    "sonar_role_counts": sonarRoleCounts,
    "sonar_nodes": recordedNodes,
    "scroll_suspects": scrollSuspects,
    "scroll_suspect_count": scrollSuspects.count,
    "parameterized_suspects": parameterizedSuspects,
    "parameterized_suspect_count": parameterizedSuspects.count,
    "value_suspects": valueSuspects,
    "value_suspect_count": valueSuspects.count,
    "all_attribute_names": Array(allAttributeNames).sorted(),
    "all_parameterized_attribute_names": Array(allParameterizedAttributeNames).sorted(),
    "all_action_names": Array(allActionNames).sorted(),
    "ax_mutation_attempted": false,
    "posted": false,
    "physical_input_posted": false,
    "os_driver_active": false,
])
