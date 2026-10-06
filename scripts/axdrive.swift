// axdrive: drive a running Mac app through the Accessibility API by process id.
// Build: swiftc -O -o /tmp/axdrive scripts/axdrive.swift
// Usage: axdrive <pid> status | list | press-id <accessibilityIdentifier> | press-desc <label> | press-title <title> | text-id <identifier>
// Used by the end-to-end checks in docs/E2E.md to open the companion menu and press its controls without moving the mouse.

import ApplicationServices
import AppKit

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func children(_ e: AXUIElement) -> [AXUIElement] {
    (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}
func str(_ e: AXUIElement, _ name: String) -> String {
    if let s = attr(e, name) as? String { return s }
    if let n = attr(e, name) as? NSNumber { return n.stringValue }
    return ""
}
func walk(_ e: AXUIElement, depth: Int, visit: (AXUIElement, Int) -> Bool) -> Bool {
    if !visit(e, depth) { return false }
    for c in children(e) { if !walk(c, depth: depth + 1, visit: visit) { return false } }
    return true
}
func describe(_ e: AXUIElement) -> String {
    let role = str(e, kAXRoleAttribute)
    let id = str(e, kAXIdentifierAttribute)
    let title = str(e, kAXTitleAttribute)
    let desc = str(e, kAXDescriptionAttribute)
    let value = str(e, kAXValueAttribute)
    var out = role
    if !id.isEmpty { out += " id=\(id)" }
    if !title.isEmpty { out += " title=\"\(title)\"" }
    if !desc.isEmpty { out += " desc=\"\(desc)\"" }
    if !value.isEmpty { out += " value=\"\(value.prefix(80))\"" }
    return out
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[1]) else {
    print("usage: axdrive <pid> status|list|press-id <id>|press-desc <desc>|press-title <title>|frame-desc <desc>|frame-title <title>|text-id <id>")
    exit(2)
}
let app = AXUIElementCreateApplication(pid)
let cmd = args[2]

func statusItem() -> AXUIElement? {
    guard let extras = attr(app, "AXExtrasMenuBar") else { return nil }
    let bar = extras as! AXUIElement
    return children(bar).first
}
func windows() -> [AXUIElement] { (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }

func find(where pred: (AXUIElement) -> Bool) -> AXUIElement? {
    var found: AXUIElement?
    for w in windows() {
        _ = walk(w, depth: 0) { e, _ in
            if pred(e) { found = e; return false }
            return true
        }
        if found != nil { break }
    }
    return found
}

switch cmd {
case "status":
    guard let item = statusItem() else { print("no status item"); exit(1) }
    let r = AXUIElementPerformAction(item, kAXPressAction as CFString)
    print("status press: \(r.rawValue)")
case "list":
    let wins = windows()
    print("windows: \(wins.count)")
    for (i, w) in wins.enumerated() {
        print("WINDOW \(i): \(describe(w))")
        _ = walk(w, depth: 0) { e, d in
            let role = str(e, kAXRoleAttribute)
            if ["AXButton", "AXStaticText", "AXTextField", "AXImage", "AXCheckBox", "AXDisclosureTriangle"].contains(role) {
                print(String(repeating: " ", count: d) + describe(e))
            }
            return true
        }
    }
case "press-id", "press-title", "press-desc":
    guard args.count >= 4 else { print("missing argument"); exit(2) }
    let needle = args[3]
    let key = cmd == "press-id" ? kAXIdentifierAttribute : (cmd == "press-desc" ? kAXDescriptionAttribute : kAXTitleAttribute)
    guard let e = find(where: { str($0, key) == needle }) else { print("not found: \(needle)"); exit(1) }
    let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
    print("press \(needle): \(r.rawValue)")
case "frame-desc", "frame-title":
    guard args.count >= 4 else { print("missing argument"); exit(2) }
    let key = cmd == "frame-desc" ? kAXDescriptionAttribute : kAXTitleAttribute
    guard let e = find(where: { str($0, key) == args[3] }) else { print("not found: \(args[3])"); exit(1) }
    var position = CGPoint.zero
    var size = CGSize.zero
    if let p = attr(e, kAXPositionAttribute) { AXValueGetValue(p as! AXValue, .cgPoint, &position) }
    if let sz = attr(e, kAXSizeAttribute) { AXValueGetValue(sz as! AXValue, .cgSize, &size) }
    print("\(Int(position.x)) \(Int(position.y)) \(Int(size.width)) \(Int(size.height))")
case "text-id":
    guard args.count >= 4 else { print("missing argument"); exit(2) }
    guard let e = find(where: { str($0, kAXIdentifierAttribute) == args[3] }) else { print("not found"); exit(1) }
    print(str(e, kAXValueAttribute))
default:
    print("unknown command")
    exit(2)
}
