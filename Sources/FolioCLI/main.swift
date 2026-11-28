import FolioAgent
import Foundation

// Conversions that use AppKit printing or WebKit hop to the main thread, so keep its run
// loop free and do the work in a task.
Task {
    let code = await CLI.main(Array(CommandLine.arguments.dropFirst()))
    exit(code)
}
dispatchMain()
