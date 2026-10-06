// Captures windows of a running app without activating it (agents' Test build).
// Usage: swift scripts/window-screenshot.swift "<owner name>" <out-prefix> [title-substring]
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: window-screenshot <owner> <out-prefix> [title]")
    exit(64)
}
let owner = args[1], prefix = args[2], titleFilter = args.count > 3 ? args[3] : nil
let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var index = 0
for window in info {
    guard window[kCGWindowOwnerName as String] as? String == owner,
          window[kCGWindowLayer as String] as? Int == 0,
          let id = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Double], (bounds["Width"] ?? 0) > 200
    else { continue }
    let title = window[kCGWindowName as String] as? String ?? ""
    if let titleFilter, !title.contains(titleFilter) { continue }
    let out = index == 0 ? "\(prefix).png" : "\(prefix)-\(index).png"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-l", String(id), "-o", "-x", out]
    try task.run()
    task.waitUntilExit()
    print("\(out)\t\(title)\t\(Int(bounds["Width"] ?? 0))x\(Int(bounds["Height"] ?? 0))")
    index += 1
}
if index == 0 { print("no windows for \(owner)"); exit(1) }
