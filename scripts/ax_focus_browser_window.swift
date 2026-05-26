import AppKit
import ApplicationServices
import Foundation

struct FocusError: Error, CustomStringConvertible {
    let description: String
}

let env = ProcessInfo.processInfo.environment
let bundleIdNeedle = env["GENESIS_V98_BROWSER_BUNDLE_ID"] ?? "com.apple.Safari"
let browserNameNeedle = (env["GENESIS_V98_BROWSER_APP"] ?? "Safari").lowercased()
let titleNeedle = (env["GENESIS_V98_WINDOW_TITLE"] ?? "The Rust Programming Language").lowercased()

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

func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard status == .success, let string = value as? String else { return "" }
    return string
}

func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard status == .success, let bool = value as? Bool else { return nil }
    return bool
}

func windows(of appElement: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
    guard status == .success, let items = value as? [AXUIElement] else { return [] }
    return items
}

func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> String {
    let status = AXUIElementSetAttributeValue(element, attribute as CFString, value as CFTypeRef)
    return statusName(status)
}

let trusted = AXIsProcessTrusted()
let runningApps = NSWorkspace.shared.runningApplications
let app = runningApps.first { candidate in
    if let bundleIdentifier = candidate.bundleIdentifier,
       bundleIdentifier.lowercased() == bundleIdNeedle.lowercased() {
        return true
    }
    return (candidate.localizedName ?? "").lowercased().contains(browserNameNeedle)
}

guard let app else {
    emit([
        "event": "v98_ax_focus_probe",
        "status": "error",
        "error": "browser app not running",
        "requested_bundle_id": bundleIdNeedle,
        "requested_browser_name": browserNameNeedle,
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
    let title = stringAttribute(window, kAXTitleAttribute)
    return title.lowercased().contains(titleNeedle)
} ?? windowList.first

let selectedTitle = selectedWindow.map { stringAttribute($0, kAXTitleAttribute) } ?? ""
let activateResult = app.activate(options: [.activateAllWindows])
let setFrontmostStatus = setBool(appElement, kAXFrontmostAttribute, true)
var raiseStatus = "not_attempted"
var setFocusedWindowStatus = "not_attempted"
var setMainStatus = "not_attempted"
var setFocusedStatus = "not_attempted"
var focusedAfter: Bool? = nil
var mainAfter: Bool? = nil

if let selectedWindow {
    raiseStatus = statusName(AXUIElementPerformAction(selectedWindow, kAXRaiseAction as CFString))
    setFocusedWindowStatus = statusName(AXUIElementSetAttributeValue(
        appElement,
        kAXFocusedWindowAttribute as CFString,
        selectedWindow
    ))
    setMainStatus = setBool(selectedWindow, kAXMainAttribute, true)
    setFocusedStatus = setBool(selectedWindow, kAXFocusedAttribute, true)
    focusedAfter = boolAttribute(selectedWindow, kAXFocusedAttribute)
    mainAfter = boolAttribute(selectedWindow, kAXMainAttribute)
}

emit([
    "event": "v98_ax_focus_probe",
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
    "set_focused_status": setFocusedStatus,
    "focused_after": focusedAfter as Any,
    "main_after": mainAfter as Any,
    "posted": false,
    "physical_input_posted": false,
    "os_driver_active": false,
])
