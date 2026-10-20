import Foundation

/// The undo and redo stacks. Each undo step holds the document from before it.
struct UndoHistory {
    /// The document as an interaction found it, and where the history stood then.
    struct Checkpoint {
        let state: EditState
        fileprivate let stepCount: Int
    }

    private struct Step {
        let before: EditState
        let number: Int
        /// Steps in a row with the same key are one continuous edit (a color panel drag).
        let coalesce: String?
    }

    private var undoStack: [Step] = []
    private var redoStack: [EditState] = []
    /// Counts the steps pushed, so an interaction knows which ones came after it began.
    private var stepCount = 0

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func checkpoint(_ state: EditState) -> Checkpoint { Checkpoint(state: state, stepCount: stepCount) }

    /// Makes the change from `before` to `current` one undo step. Steps pushed in the meantime (a weight
    /// picked while typing) fold into it. A step with the same `coalesce` key as the one just before it
    /// merges into that one. No change, no step.
    mutating func commit(from before: Checkpoint, to current: EditState, coalesce key: String?) {
        guard current != before.state else { return }
        undoStack.removeAll { $0.number > before.stepCount }
        if let key, let last = undoStack.last, last.coalesce == key, last.number == stepCount { return }
        push(before.state, coalesce: key)
        redoStack.removeAll()
    }

    /// The document to go back to, or nil when there is nothing to undo.
    mutating func undo(from current: EditState) -> EditState? {
        guard let step = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return step.before
    }

    mutating func redo(from current: EditState) -> EditState? {
        guard let next = redoStack.popLast() else { return nil }
        push(current, coalesce: nil)
        return next
    }

    private mutating func push(_ before: EditState, coalesce key: String?) {
        stepCount += 1
        undoStack.append(Step(before: before, number: stepCount, coalesce: key))
        if undoStack.count > 300 { undoStack.removeFirst() }
    }
}
