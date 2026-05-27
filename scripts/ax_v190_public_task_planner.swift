import AppKit
import ApplicationServices
import Foundation

let env = ProcessInfo.processInfo.environment
let bundleIdNeedle = env["GENESIS_V190_BROWSER_BUNDLE_ID"] ?? "com.apple.Safari"
let browserNameNeedle = (env["GENESIS_V190_BROWSER_APP"] ?? "Safari").lowercased()
let titleNeedle = (env["GENESIS_V190_WINDOW_TITLE"] ?? "Modal Dialog Example").lowercased()
let targetUrl = env["GENESIS_V190_TARGET_URL"] ?? "https://www.w3.org/WAI/ARIA/apg/patterns/dialog-modal/examples/dialog/"
let domainLock = env["GENESIS_V190_URL_DOMAIN_LOCK"] ?? "w3.org/WAI/ARIA/apg/patterns/dialog-modal/examples/dialog"
let triggerNeedle = (env["GENESIS_V190_TRIGGER_TITLE"] ?? "Add Delivery Address").lowercased()
let expectedFieldNeedle = env["GENESIS_V190_EXPECT_FIELD_TITLE"] ?? "Street"
let expectedCommitNeedle = env["GENESIS_V190_EXPECT_COMMIT_TITLE"] ?? "Verify Address"
let expectedSuccessNeedle = env["GENESIS_V190_EXPECT_SUCCESS_TITLE"] ?? "Verification Result"
let maxDepth = Int(env["GENESIS_V190_AX_MAX_DEPTH"] ?? "14") ?? 14
let maxNodes = Int(env["GENESIS_V190_AX_MAX_NODES"] ?? "4200") ?? 4200

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
    guard status == .success, let value else { return "" }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    if let bool = value as? Bool { return bool ? "true" : "false" }
    return ""
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
        stringAttribute(element, "AXDOMIdentifier"),
        stringAttribute(element, "AXDOMClassList"),
    ].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

func rolePayload(_ element: AXUIElement, depth: Int, path: [Int]) -> [String: Any] {
    [
        "role": stringAttribute(element, kAXRoleAttribute),
        "subrole": stringAttribute(element, kAXSubroleAttribute),
        "title": stringAttribute(element, kAXTitleAttribute),
        "description": stringAttribute(element, kAXDescriptionAttribute),
        "value": stringAttribute(element, kAXValueAttribute),
        "frame": jsonValue(rectAttribute(element, "AXFrame")),
        "actions": actionNames(element),
        "depth": depth,
        "path": path,
        "child_count": children(of: element).count,
    ]
}

func centerPoint(_ frame: [String: Double]?) -> Any {
    guard let frame else { return NSNull() }
    return [
        "x": frame["center_x"] ?? 0,
        "y": frame["center_y"] ?? 0,
    ]
}

func visibleFrame(_ frame: [String: Double]?) -> Bool {
    guard let frame else { return false }
    return (frame["width"] ?? 0) > 1 && (frame["height"] ?? 0) > 1 && (frame["area"] ?? 0) > 4
}

func roleKind(role: String, actions: [String], label: String) -> String? {
    let lowered = label.lowercased()
    if role == "AXTextField" || role == "AXTextArea" { return "text_input" }
    if role == "AXCheckBox" { return "checkbox" }
    if role == "AXRadioButton" { return "radio" }
    if role == "AXComboBox" || role == "AXPopUpButton" { return "combobox" }
    if role == "AXButton" { return "button" }
    if role == "AXLink" { return "link" }
    if role == "AXHeading" { return "heading" }
    if role == "AXStaticText" && lowered.count > 8 { return "static_text" }
    if actions.contains("AXPress") { return "pressable" }
    return nil
}

func shouldDescend(role: String, depth: Int) -> Bool {
    guard depth < maxDepth else { return false }
    return [
        "AXWindow",
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
        "AXButton",
        "AXHeading",
        "AXStaticText",
        "AXTextField",
        "AXTextArea",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXComboBox",
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
        "event": "v190_public_task_planner",
        "status": "error",
        "error": "browser app not running",
        "posted": false,
        "physical_input_posted": false,
        "os_driver_active": false,
        "accessibility_api_trusted": trusted,
    ])
    exit(1)
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)
let windowList = windows(of: appElement)
let matchingWindows = windowList.filter { window in
    stringAttribute(window, kAXTitleAttribute).lowercased().contains(titleNeedle)
}
let selectedWindow = matchingWindows.first ?? windowList.first

guard let selectedWindow else {
    emit([
        "event": "v190_public_task_planner",
        "status": "error",
        "error": "no browser window found",
        "posted": false,
        "physical_input_posted": false,
        "os_driver_active": false,
        "accessibility_api_trusted": trusted,
    ])
    exit(1)
}

var queue = [QueueItem(element: selectedWindow, depth: 0, path: [])]
var visited = 0
var controls: [[String: Any]] = []
var triggerCandidates: [[String: Any]] = []
var modalCandidates: [[String: Any]] = []
var isrRiskCandidates: [[String: Any]] = []
var terminationCandidates: [[String: Any]] = []

while !queue.isEmpty && visited < maxNodes {
    let item = queue.removeFirst()
    visited += 1

    let role = stringAttribute(item.element, kAXRoleAttribute)
    let label = haystack(item.element)
    let actions = actionNames(item.element)
    let frame = rectAttribute(item.element, "AXFrame")
    let payload = rolePayload(item.element, depth: item.depth, path: item.path)
    let labelLower = label.lowercased()

    if let kind = roleKind(role: role, actions: actions, label: label),
       visibleFrame(frame) {
        var control = payload
        control["control_kind"] = kind
        control["label"] = label
        control["global_coregraphics_point"] = centerPoint(frame)
        control["posted"] = false
        control["physical_input_posted"] = false
        controls.append(control)

        if labelLower.contains(triggerNeedle) {
            triggerCandidates.append(control)
        }
        if labelLower.contains(expectedSuccessNeedle.lowercased()) {
            terminationCandidates.append(control)
        }
    }

    if ["AXDialog", "AXSheet", "AXPopover"].contains(role) {
        var modal = payload
        modal["label"] = label
        modal["occluder_kind"] = "modal"
        modal["global_coregraphics_point"] = centerPoint(frame)
        modalCandidates.append(modal)
    }

    if labelLower.contains("dialog")
        || labelLower.contains("modal")
        || labelLower.contains("popup")
        || labelLower.contains("cookie")
        || labelLower.contains("consent")
        || labelLower.contains("privacy") {
        var risk = payload
        risk["label"] = label
        risk["risk_kind"] = "potential_isr_surface"
        isrRiskCandidates.append(risk)
    }

    if shouldDescend(role: role, depth: item.depth) {
        for (index, child) in children(of: item.element).enumerated() {
            queue.append(QueueItem(element: child, depth: item.depth + 1, path: item.path + [index]))
        }
    }
}

let selectedTrigger = triggerCandidates.first
let controlsByKind = Dictionary(grouping: controls) { ($0["control_kind"] as? String) ?? "unknown" }
let observedControlTypes = controlsByKind.keys.sorted()
let modalActive = !modalCandidates.isEmpty
let planSteps: [[String: Any]]

if let selectedTrigger {
    planSteps = [
        [
            "step_id": "step-0-trigger-modal",
            "phase": "state_activation",
            "target_label": triggerNeedle,
            "control_type": selectedTrigger["control_kind"] ?? "button",
            "planned_weapon": "physical_click_after_validation",
            "requires_fresh_remap_before_fire": true,
            "expected_state_after": "modal_active",
            "posted": false,
            "physical_input_posted": false,
        ],
        [
            "step_id": "step-1-fill-text-field",
            "phase": "deferred_modal_business_mutation",
            "target_label": expectedFieldNeedle,
            "control_type": "text_input",
            "planned_weapon": "v16_textfield_transport",
            "requires_modal_visible": true,
            "requires_fresh_remap_before_fire": true,
            "posted": false,
            "physical_input_posted": false,
        ],
        [
            "step_id": "step-2-commit-form",
            "phase": "deferred_modal_commit",
            "target_label": expectedCommitNeedle,
            "control_type": "button",
            "planned_weapon": "physical_click_after_validation",
            "requires_modal_visible": true,
            "termination_expectation": expectedSuccessNeedle,
            "posted": false,
            "physical_input_posted": false,
        ],
    ]
} else {
    planSteps = []
}

let domainLocked = targetUrl.contains(domainLock)
let safeToArm = domainLocked
    && selectedTrigger != nil
    && !modalActive
    && planSteps.count >= 3

emit([
    "event": "v190_public_task_plan",
    "status": "ok",
    "taxonomy_version": "v19.0-public-read-only-task-planner",
    "accessibility_api_trusted": trusted,
    "browser_pid": app.processIdentifier,
    "browser_bundle_id": app.bundleIdentifier ?? "",
    "browser_localized_name": app.localizedName ?? "",
    "target_url": targetUrl,
    "domain_lock": domainLock,
    "domain_locked": domainLocked,
    "selected_window_title": stringAttribute(selectedWindow, kAXTitleAttribute),
    "window_frame": jsonValue(rectAttribute(selectedWindow, "AXFrame")),
    "visited_count": visited,
    "control_count": controls.count,
    "control_type_coverage": observedControlTypes,
    "control_type_counts": controlsByKind.mapValues { $0.count },
    "target_sequence": planSteps,
    "target_sequence_count": planSteps.count,
    "trigger_found": selectedTrigger != nil,
    "trigger_candidate_count": triggerCandidates.count,
    "trigger_candidate": jsonValue(selectedTrigger),
    "modal_active_on_load": modalActive,
    "public_obstacle_seen": modalActive,
    "isr_prediction": [
        "expected_interrupt_points": modalActive ? ["pre_existing_modal"] : ["after_step-0-trigger-modal"],
        "active_modal_count": modalCandidates.count,
        "potential_isr_surface_count": isrRiskCandidates.count,
        "policy": "read_only_predict_only",
    ],
    "termination_conditions": [
        "expect_static_text_contains": expectedSuccessNeedle,
        "url_must_remain_within_domain_lock": true,
        "domain_lock": domainLock,
    ],
    "deferred_controls": [
        [
            "label": expectedFieldNeedle,
            "control_type": "text_input",
            "visibility": "deferred_until_modal_activation",
        ],
        [
            "label": expectedCommitNeedle,
            "control_type": "button",
            "visibility": "deferred_until_modal_activation",
        ],
    ],
    "safe_to_arm": safeToArm,
    "plan_ready": safeToArm,
    "posted": false,
    "physical_input_posted": false,
    "os_driver_active": false,
])
