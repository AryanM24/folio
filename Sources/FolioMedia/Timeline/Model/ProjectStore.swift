import Foundation
import Observation

/// The live project behind one editor window: observable, and undoable by snapshot.
///
/// Every change goes through `edit(_:_:)`, which registers the previous `Project` value with
/// the window's undo manager (so autosave sees it, see docs/ARCHITECTURE.md). `Project` is
/// a value with copy-on-write arrays, so a snapshot per step is cheap and far simpler than
/// inverse operations.
///
/// Continuous gestures (dragging a clip, scrubbing a slider) call `beginGesture` and
/// `endGesture`: everything in between becomes one undo step.
///
/// Observation is hand-written rather than `@Observable` so the store can be created in
/// the document's nonisolated `init` (SwiftUI reads documents off the main actor).
@MainActor
final class ProjectStore: Observable {
    /// Set by the editor view from `@Environment(\.undoManager)`, the document's.
    weak var undoManager: UndoManager?

    private let registrar = ObservationRegistrar()
    private var storage: Project
    private var gesture: (name: String, before: Project)?

    nonisolated init(project: Project) {
        storage = project
    }

    var project: Project {
        registrar.access(self, keyPath: \.project)
        return storage
    }

    var isInGesture: Bool { gesture != nil }

    /// Applies `body` to a copy and keeps it if it didn't throw, as one undo step named
    /// `actionName` ("Split Clip"). A throw or a no-op change leaves no trace.
    @discardableResult
    func edit<T>(_ actionName: String, _ body: (inout Project) throws -> T) rethrows -> T {
        var copy = storage
        let result = try body(&copy)
        guard copy != storage else { return result }
        let before = storage
        set(copy)
        if gesture == nil { registerUndo(restoring: before, actionName) }
        return result
    }

    /// Starts coalescing: edits until `endGesture` make a single undo step.
    func beginGesture(_ actionName: String) {
        if gesture == nil { gesture = (actionName, storage) }
    }

    func endGesture() {
        guard let gesture else { return }
        self.gesture = nil
        if storage != gesture.before { registerUndo(restoring: gesture.before, gesture.name) }
    }

    /// Puts things back as they were when the gesture began (Esc during a drag).
    func cancelGesture() {
        guard let gesture else { return }
        self.gesture = nil
        set(gesture.before)
    }

    private func set(_ value: Project) {
        registrar.withMutation(of: self, keyPath: \.project) { storage = value }
    }

    private func registerUndo(restoring value: Project, _ name: String) {
        guard let undoManager else { return }
        // An explicit group, so it works whether or not the manager groups by event.
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        if grouping { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.restore(value, name) }
        }
        undoManager.setActionName(name)
        if grouping { undoManager.endUndoGrouping() }
    }

    /// Undo and redo: swap the snapshot back and register the opposite step.
    private func restore(_ value: Project, _ name: String) {
        gesture = nil
        let current = storage
        set(value)
        registerUndo(restoring: current, name)
    }
}
