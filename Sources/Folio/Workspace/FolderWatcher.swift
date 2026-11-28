import Foundation

/// Calls `onChange` (on the main actor, coalesced) when a folder's direct contents change:
/// a file added, removed or renamed, by Folio or by anything else.
///
/// Uses a kqueue vnode source on the folder itself, which is cheap and needs no
/// FSEvents stream; changes inside subfolders don't fire, which matches a one-level view.
final class FolderWatcher {
    private var source: (any DispatchSourceFileSystemObject)?
    private var pending: DispatchWorkItem?
    private var cancelled = false

    init(_ url: URL, onChange: @escaping @MainActor () -> Void) {
        let path = url.path(percentEncoded: false)
        // Opening ~/Documents or ~/Desktop can block until the person answers macOS's
        // folder-access prompt, so never open on the main thread: the window must draw first.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.cancelled else { close(fd); return }
                    self.start(fd, onChange: onChange)
                }
            }
        }
    }

    private func start(_ fd: Int32, onChange: @escaping @MainActor () -> Void) {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // Saving a document touches a folder several times in a row; reload once.
                self?.pending?.cancel()
                let work = DispatchWorkItem { MainActor.assumeIsolated { onChange() } }
                self?.pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func cancel() {
        cancelled = true
        pending?.cancel()
        source?.cancel()
        source = nil
    }
}
