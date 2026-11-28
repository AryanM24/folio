import CoreImage
import Synchronization

/// Custom Core Image kernels compiled from Metal source at run time
/// (`CIKernel.kernels(withMetalString:)`), so they build without Xcode's `metal` tool.
///
/// Each package keeps its own Metal source next to the code that uses it and asks here
/// for the compiled kernel. Every function needs `[[stitchable]]` and the source needs
/// `#include <CoreImage/CoreImage.h>` (no `extern "C"`). A source compiles once (about
/// 0.3 s on an M4), then comes from the cache; warm it up off the main thread.
///
/// Keep one kernel per source string. With several kernels compiled from one source,
/// parallel renders were seen returning another kernel's output (WP3's tone kernels).
nonisolated enum Kernels {
    private static let cache = Mutex<[String: [CIKernel]]>([:])

    /// The kernel named `name` in `source`, or `nil` when the source doesn't compile
    /// (callers fall back to built-in filters). Color kernels come back as
    /// `CIColorKernel`, warp kernels as `CIWarpKernel`.
    static func kernel(named name: String, in source: String) -> CIKernel? {
        let compiled =
            cache.withLock { $0[source] }
            ?? {
                // Compile outside the lock; a rare duplicate compile is harmless.
                let kernels = (try? CIKernel.kernels(withMetalString: source)) ?? []
                cache.withLock { $0[source] = kernels }
                return kernels
            }()
        return compiled.first { $0.name == name }
    }
}
