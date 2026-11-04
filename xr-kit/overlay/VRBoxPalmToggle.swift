// SPDX-License-Identifier: GPL-2.0-or-later

/// Recognizes a deliberate open palm once and waits for the hand to relax or leave.
struct VRBoxPalmToggle {
    private var lastSample: Double?
    private var changeSince: Double?
    private var latched = false

    mutating func update(open: Bool?, at timestamp: Double) -> Bool {
        if let previous = lastSample {
            guard timestamp > previous else { return false }
            if timestamp - previous > 0.25 { changeSince = nil }
        }
        lastSample = timestamp

        let isOpen = open == true
        guard isOpen != latched else {
            changeSince = nil
            return false
        }
        let since = changeSince ?? timestamp
        changeSince = since
        let dwell = isOpen ? 0.65 : (open == nil ? 0.45 : 0.18)
        guard timestamp - since >= dwell else { return false }

        latched = isOpen
        changeSince = nil
        return isOpen
    }
}
