import Foundation

/// Undo/redo history of whole-state snapshots.
///
/// The editor's state is small (zoom keyframes and edit settings), so each undo step
/// just remembers the state from before the edit. Edits made in quick succession under
/// the same coalescing key (typing in a text field, nudging the same control) collapse
/// into one step, so undo goes back to where that burst started rather than one
/// keystroke at a time.
struct EditHistory<State: Equatable> {
    struct Entry {
        let state: State
        let actionName: String
    }

    private(set) var undoStack: [Entry] = []
    private(set) var redoStack: [Entry] = []

    /// Maximum number of undo steps kept; the oldest are dropped first.
    let limit: Int
    /// Edits with the same coalescing key closer together than this merge into one step.
    let coalescingInterval: TimeInterval

    private var lastCoalescingKey: AnyHashable?
    private var lastEditTime: TimeInterval = -.infinity

    init(limit: Int = 100, coalescingInterval: TimeInterval = 1.0) {
        self.limit = max(1, limit)
        self.coalescingInterval = coalescingInterval
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoActionName: String? { undoStack.last?.actionName }
    var redoActionName: String? { redoStack.last?.actionName }

    /// Records an edit. Call it with the state from *before* the edit was applied.
    ///
    /// - Parameters:
    ///   - previous: the state to return to on undo.
    ///   - coalescingKey: edits with the same key within `coalescingInterval` of each
    ///     other form one undo step. `nil` always starts a new step.
    ///   - now: a monotonic timestamp in seconds.
    mutating func record(
        _ previous: State,
        actionName: String,
        coalescingKey: AnyHashable? = nil,
        now: TimeInterval
    ) {
        defer {
            lastCoalescingKey = coalescingKey
            lastEditTime = now
        }
        // Any new edit invalidates what could be redone.
        redoStack.removeAll()

        if let coalescingKey,
           coalescingKey == lastCoalescingKey,
           now - lastEditTime < coalescingInterval,
           !undoStack.isEmpty {
            // Part of the same burst: the existing step already holds the state from
            // before the burst started.
            return
        }

        undoStack.append(Entry(state: previous, actionName: actionName))
        if undoStack.count > limit {
            undoStack.removeFirst(undoStack.count - limit)
        }
    }

    /// Steps back. Returns the state to restore, or `nil` if there is nothing to undo.
    /// - Parameter current: the state being left, kept so it can be redone.
    mutating func undo(from current: State) -> State? {
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.append(Entry(state: current, actionName: entry.actionName))
        breakCoalescing()
        return entry.state
    }

    /// Steps forward again. Returns the state to restore, or `nil` if there is nothing
    /// to redo.
    mutating func redo(from current: State) -> State? {
        guard let entry = redoStack.popLast() else { return nil }
        undoStack.append(Entry(state: current, actionName: entry.actionName))
        breakCoalescing()
        return entry.state
    }

    /// Makes the next edit start a new step even if it has the same coalescing key.
    mutating func breakCoalescing() {
        lastCoalescingKey = nil
        lastEditTime = -.infinity
    }
}
