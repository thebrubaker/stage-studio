// WindowEnumerator — the picker's list of recordable windows.
//
// Same approach as cmd/windows (CGWindowList, layer 0, ≥100px, excludes self),
// kept in-process rather than shelling out: the picker needs pids and live app
// icons, and a JSON round-trip through a second binary would only lose them.
//
// CGWindowList gives bounds and app names without any permission. TITLES require
// Screen Recording — before the grant, windows come back titled "" and the picker
// falls back to showing just the app name.

import AppKit
import CoreGraphics

struct CapturableWindow: Identifiable, Equatable {
    let id: CGWindowID
    let app: String
    let title: String
    let pid: pid_t
    /// Screen POINTS, top-left origin (CGWindowList's space).
    let bounds: CGRect

    /// What the picker shows under the thumbnail: app name on top, window title
    /// beneath. An untitled window (or a missing Screen Recording grant) just
    /// leaves the second line empty rather than inventing something.
    var subtitle: String { title }

    var icon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }
}

enum WindowEnumerator {
    /// Minimum edge length, matching cmd/windows — filters out chrome that slips
    /// past the layer filter.
    static let minimumEdge: CGFloat = 100

    static func list(excludingPID excluded: pid_t = ProcessInfo.processInfo.processIdentifier) -> [CapturableWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var out: [CapturableWindow] = []
        for w in raw {
            // Layer 0 = normal app windows. Higher layers are menubar, dock,
            // overlays — and our own pill, which lives at .screenSaver.
            guard (w[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }

            let app = w[kCGWindowOwnerName as String] as? String ?? ""
            guard !app.isEmpty else { continue }

            let pid = pid_t(w[kCGWindowOwnerPID as String] as? Int ?? 0)
            guard pid != excluded else { continue }

            guard let id = w[kCGWindowNumber as String] as? Int,
                  let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            guard rect.width >= minimumEdge, rect.height >= minimumEdge else { continue }

            out.append(CapturableWindow(
                id: CGWindowID(id),
                app: app,
                title: w[kCGWindowName as String] as? String ?? "",
                pid: pid,
                bounds: rect
            ))
        }
        // CGWindowList returns front-to-back, which is already the order the user
        // thinks in — the window they just left is first.
        return out
    }
}
