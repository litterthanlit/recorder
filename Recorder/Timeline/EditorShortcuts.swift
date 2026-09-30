import Foundation

/// Something a key press does in the editor.
enum EditorCommand: Equatable {
    case togglePlayback
    /// Move the playhead by whole frames (negative is back).
    case stepFrames(Int)
    case stepSeconds(Double)
    case goToStart
    case goToEnd
    case split
    case deleteSelection
    case addZoom
    case addText
    case addBlur
    case export
    case timelineZoomIn
    case timelineZoomOut
    case timelineZoomToFit
    /// Move the selected zoom, text or blur in time.
    case nudgeSelection(TimeInterval)
    case clearSelection
    case undo
    case redo
}

/// The editor's single-key shortcuts, kept in one table so the key handler and the help
/// text agree.
enum EditorShortcuts {
    /// The command for a key press, or `nil` to let the window handle it.
    /// - Parameters:
    ///   - keyCode: virtual key code (`kVK_…`).
    ///   - modifiers: Carbon modifier masks (`KeyCombo.Modifier`).
    ///   - character: the key's character without modifiers, so letter shortcuts follow
    ///     the keyboard layout (Z is where the user's Z is).
    static func command(keyCode: UInt32, modifiers: UInt32, character: String?) -> EditorCommand? {
        let mods = modifiers & KeyCombo.Modifier.all
        let command = KeyCombo.Modifier.command
        let shift = KeyCombo.Modifier.shift
        let option = KeyCombo.Modifier.option

        switch keyCode {
        case KeyNames.Code.space:
            return mods == 0 ? .togglePlayback : nil
        case KeyNames.Code.leftArrow, KeyNames.Code.rightArrow:
            let sign: Double = keyCode == KeyNames.Code.leftArrow ? -1 : 1
            switch mods {
            case 0: return .stepFrames(Int(sign))
            case shift: return .stepSeconds(sign)
            case option: return .nudgeSelection(0.1 * sign)
            case option | shift: return .nudgeSelection(sign)
            case command: return sign < 0 ? .goToStart : .goToEnd
            default: return nil
            }
        case Code.home:
            return mods == 0 ? .goToStart : nil
        case Code.end:
            return mods == 0 ? .goToEnd : nil
        case KeyNames.Code.delete, KeyNames.Code.forwardDelete:
            return mods == 0 || mods == command ? .deleteSelection : nil
        case KeyNames.Code.escape:
            return mods == 0 ? .clearSelection : nil
        default:
            break
        }

        guard let key = character?.lowercased(), key.count == 1 else { return nil }
        switch mods {
        case 0:
            switch key {
            case "s": return .split
            case "z": return .addZoom
            case "t": return .addText
            case "b": return .addBlur
            default: return nil
            }
        case command:
            switch key {
            case "z": return .undo
            case "b": return .split
            case "e": return .export
            case "=", "+": return .timelineZoomIn
            case "-": return .timelineZoomOut
            case "0": return .timelineZoomToFit
            default: return nil
            }
        case command | shift:
            if key == "z" {
                return .redo
            }
            // ⌘+ on layouts where + needs Shift.
            return key == "=" || key == "+" ? .timelineZoomIn : nil
        default:
            return nil
        }
    }

    /// For the shortcut reference in the editor.
    static let reference: [(keys: String, action: String)] = [
        ("Space", "Play or pause"),
        ("← →", "Previous or next frame"),
        ("⇧← ⇧→", "Back or forward one second"),
        ("S or ⌘B", "Split at the playhead"),
        ("⌫", "Delete the selection"),
        ("Z", "Add a zoom"),
        ("T", "Add text"),
        ("B", "Add a blur"),
        ("⌥← ⌥→", "Nudge the selection"),
        ("⌘+ ⌘−", "Zoom the timeline"),
        ("⌘Z ⇧⌘Z", "Undo or redo"),
        ("⌘E", "Export")
    ]

    private enum Code {
        static let home: UInt32 = 0x73
        static let end: UInt32 = 0x77
    }
}
