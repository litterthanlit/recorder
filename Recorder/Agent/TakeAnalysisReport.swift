import CoreGraphics
import Foundation

/// The analysis as agents read it: source seconds, points normalized from the top-left,
/// and the suggested edit as operations for edit_timeline.
extension TakeAnalysis {
    var json: JSONValue {
        let suggested = suggestedTimeline()
        var value: [String: JSONValue] = [:]
        value["duration"] = AgentTime.json(duration)
        value["kept"] = Self.json(kept)
        value["lead_in"] = leadIn.map { Self.json($0) } ?? JSONValue.null
        value["tail"] = tail.map { Self.json($0) } ?? JSONValue.null
        value["dead"] = .array(dead.map { Self.json($0) })
        value["quiet"] = .array(quiet.map { Self.json($0) })
        value["beats"] = .array(beats.map { Self.json($0) })
        if let speech {
            value["speech"] = .array(speech.map { Self.json($0) })
        } else {
            value["speech"] = "No microphone was recorded."
        }
        value["screen_scanned"] = .bool(screenActivity != nil)
        if let focusApp {
            value["focus_app"] = .string(focusApp)
            value["off_app"] = .array(offApp.map { Self.json($0) })
            value["covers"] = .array(covers.map { Self.json($0) })
            value["apps"] = .array(apps.map { share -> JSONValue in
                ["name": .string(share.appName), "seconds": AgentTime.json(share.seconds)]
            })
        } else {
            value["focus_app"] = "Unknown: this take doesn't record which app was in front."
        }
        var suggestion: [String: JSONValue] = [
            "operations": .array(suggestedOperations),
            "output_duration": AgentTime.json(suggested.outputDuration),
            "note": "Pass operations to edit_timeline as they are (source time). They start with reset, so they replace the current edit."
        ]
        let blurs = suggestedBlurOperations
        if !blurs.isEmpty {
            suggestion["blur_operations"] = .array(blurs)
            suggestion["blur_note"] = "Pass blur_operations to edit_blur (source time): they hide other apps' windows over the app's."
        }
        value["suggested"] = .object(suggestion)
        return .object(value)
    }

    /// edit_blur operations hiding the covers that are blurred, one box per place.
    var suggestedBlurOperations: [JSONValue] {
        covers.filter { $0.action == .blur }.flatMap { cover in
            cover.pieces.map { piece -> JSONValue in
                [
                    "op": "add",
                    "start": AgentTime.json(piece.span.start),
                    "end": AgentTime.json(piece.span.end),
                    "rect": AgentCoordinates.json(sourceRect: piece.rect),
                    "strength": .number(TakeAnalysis.coverBlurStrength)
                ]
            }
        }
    }

    /// Heavy enough that another app's text can't be read.
    static let coverBlurStrength = 0.9

    /// The suggested edit as edit_timeline operations, starting from the whole recording.
    var suggestedOperations: [JSONValue] {
        var operations: [JSONValue] = [["op": "reset"]]
        if kept.start > 0 || kept.end < duration {
            operations.append(["op": "trim", "start": AgentTime.json(kept.start), "end": AgentTime.json(kept.end)])
        }
        for cut in cuts {
            operations.append(["op": "cut", "start": AgentTime.json(cut.start), "end": AgentTime.json(cut.end)])
        }
        for speedUp in speedUps {
            operations.append([
                "op": "speed",
                "start": AgentTime.json(speedUp.span.start),
                "end": AgentTime.json(speedUp.span.end),
                "speed": .number(speedUp.speed)
            ])
        }
        return operations
    }

    /// One line for people: what was found and what the suggestion does.
    var summary: String {
        var parts: [String] = []
        if let leadIn {
            parts.append("lead-in \(Self.seconds(leadIn.duration))")
        }
        if let tail {
            parts.append("tail \(Self.seconds(tail.duration))")
        }
        if !dead.isEmpty {
            let total = dead.reduce(0) { $0 + $1.duration }
            parts.append("\(dead.count) dead stretch\(dead.count == 1 ? "" : "es") (\(Self.seconds(total)))")
        }
        if !quiet.isEmpty {
            let total = quiet.reduce(0) { $0 + $1.duration }
            parts.append("\(quiet.count) wait\(quiet.count == 1 ? "" : "s") (\(Self.seconds(total)))")
        }
        if !offApp.isEmpty, let focusApp {
            let total = offApp.reduce(0) { $0 + $1.duration }
            parts.append("\(offApp.count) detour\(offApp.count == 1 ? "" : "s") away from \(focusApp) (\(Self.seconds(total)))")
        }
        if !covers.isEmpty, let focusApp {
            let actions = [TakeAnalysis.Cover.Action.cut, .blur, .keep].compactMap { action -> String? in
                let count = covers.filter { $0.action == action }.count
                guard count > 0 else { return nil }
                switch action {
                case .cut: return "\(count) cut"
                case .blur: return "\(count) blurred"
                case .keep: return "\(count) kept while talking"
                }
            }
            parts.append("\(covers.count) other app\(covers.count == 1 ? "" : "s") over \(focusApp) (\(actions.joined(separator: ", ")))")
        }
        if let speech, !speech.isEmpty {
            let total = speech.reduce(0) { $0 + $1.duration }
            parts.append("speech \(Self.seconds(total))")
        }
        let found = parts.isEmpty ? "nothing to take out" : parts.joined(separator: ", ")
        let output = suggestedTimeline().outputDuration
        return "\(Self.seconds(duration)) take: \(found). Suggested edit: \(Self.seconds(duration)) → \(Self.seconds(output))."
    }

    static func json(_ span: TimeSpan) -> JSONValue {
        ["start": AgentTime.json(span.start), "end": AgentTime.json(span.end), "duration": AgentTime.json(span.duration)]
    }

    static func json(_ cover: Cover) -> JSONValue {
        [
            "app": .string(cover.appName),
            "start": AgentTime.json(cover.span.start),
            "end": AgentTime.json(cover.span.end),
            "share_of_window": .number((cover.share * 1000).rounded() / 1000),
            "action": .string(cover.action.rawValue),
            "places": .array(cover.pieces.map { piece -> JSONValue in
                [
                    "start": AgentTime.json(piece.span.start),
                    "end": AgentTime.json(piece.span.end),
                    "rect": AgentCoordinates.json(sourceRect: piece.rect)
                ]
            })
        ]
    }

    static func json(_ beat: Beat) -> JSONValue {
        var value: [String: JSONValue] = [
            "kind": .string(beat.kind.rawValue),
            "start": AgentTime.json(beat.span.start),
            "end": AgentTime.json(beat.span.end),
            "count": .number(Double(beat.count))
        ]
        if let location = beat.location {
            value["point"] = AgentCoordinates.json(sourcePoint: location)
        }
        return .object(value)
    }

    static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f s", value)
    }
}
