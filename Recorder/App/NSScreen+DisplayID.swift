import AppKit

extension NSScreen {
    var displayIdentifier: CGDirectDisplayID {
        guard
            let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return CGMainDisplayID()
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    /// The screen showing `displayID`, if it's connected.
    static func screen(forDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayIdentifier == displayID }
    }
}
