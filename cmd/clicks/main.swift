// stage input recorder — taps mouse-down + mouseMoved + drag events and emits JSONL to stdout.
//
// Output schema (one line per event):
//   clicks:  {"kind":"click","epoch":1715617900.123,"x":824.0,"y":512.0,"button":"left"}
//   moves:   {"kind":"move","epoch":1715617900.150,"x":826.2,"y":512.4}
//
// Move events are throttled to ~60Hz (one sample per ~16ms) — sufficient for smooth
// camera following without flooding stdout.
//
// Requires BOTH on macOS Sequoia+ (Privacy & Security):
//   - Accessibility — for tap creation
//   - Input Monitoring — for mouseDown events to reach the tap. Without it, only
//     mouseMoved/dragged events arrive (clicks silently filtered upstream).
// Grant the permissions to the parent terminal app (cmux, Terminal, iTerm, etc.).
// Restart the parent app after enabling Input Monitoring for the change to apply.
// Compile:
//   swiftc -O main.swift -o clicks
// Stop: SIGINT (Ctrl-C) or SIGTERM.

import Cocoa
import CoreGraphics
import Foundation

// Move throttle: skip emit if last move was less than MOVE_MIN_INTERVAL_S ago.
let MOVE_MIN_INTERVAL_S: Double = 1.0 / 60.0
var lastMoveEpoch: Double = 0

func emit(_ event: CGEvent, type: CGEventType) {
    let loc = event.location
    let epoch = Date().timeIntervalSince1970
    let line: String

    switch type {
    case .leftMouseDown:
        line = #"{"kind":"click","epoch":\#(epoch),"x":\#(loc.x),"y":\#(loc.y),"button":"left"}"#
    case .rightMouseDown:
        line = #"{"kind":"click","epoch":\#(epoch),"x":\#(loc.x),"y":\#(loc.y),"button":"right"}"#
    case .otherMouseDown:
        line = #"{"kind":"click","epoch":\#(epoch),"x":\#(loc.x),"y":\#(loc.y),"button":"other"}"#
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
        if epoch - lastMoveEpoch < MOVE_MIN_INTERVAL_S { return }
        lastMoveEpoch = epoch
        line = #"{"kind":"move","epoch":\#(epoch),"x":\#(loc.x),"y":\#(loc.y)}"#
    default:
        return
    }

    print(line)
    fflush(stdout)
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    emit(event, type: type)
    return Unmanaged.passUnretained(event)
}

// CGEventMask is UInt64; explicit construction avoids any Int-default surprises.
func bit(_ t: CGEventType) -> CGEventMask { CGEventMask(1) << CGEventMask(t.rawValue) }
let mask: CGEventMask =
    bit(.leftMouseDown)  |
    bit(.rightMouseDown) |
    bit(.otherMouseDown) |
    bit(.mouseMoved)     |
    bit(.leftMouseDragged) |
    bit(.rightMouseDragged) |
    bit(.otherMouseDragged)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: mask,
    callback: callback,
    userInfo: nil
) else {
    FileHandle.standardError.write(Data("stage: failed to create event tap — grant Accessibility permission in System Settings\n".utf8))
    exit(1)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

// Emit display geometry on stdout as the first event so the parent CLI can
// scale the ffmpeg capture to point dimensions (cursor coords are in points,
// ffmpeg captures in pixels — matching the two avoids DPR math everywhere else).
if let screen = NSScreen.main {
    let frame = screen.frame
    let scale = screen.backingScaleFactor
    let meta = #"{"kind":"meta","pointWidth":\#(Int(frame.width)),"pointHeight":\#(Int(frame.height)),"backingScale":\#(scale)}"#
    print(meta)
    fflush(stdout)
}

// Stderr breadcrumb so the parent process can detect we're live.
FileHandle.standardError.write(Data("stage-input: ready\n".utf8))

CFRunLoopRun()
