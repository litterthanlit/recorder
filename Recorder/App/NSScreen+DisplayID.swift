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
}
