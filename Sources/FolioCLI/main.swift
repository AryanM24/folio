import FolioAgent
import Foundation

// Conversions that use AppKit printing or WebKit hop to the main actor, so keep the real
// main thread free and do the work in a task. Not `dispatchMain()`: it exits the main
// thread, and AppKit then refuses to build its text views on whatever thread runs the queue.
Task {
    let code = await CLI.main(Array(CommandLine.arguments.dropFirst()))
    exit(code)
}
RunLoop.main.run()
