import AppKit
import SwiftUI

/// Hosts the grid in an `NSScrollView` for SwiftUI.
struct GridContainer: NSViewRepresentable {
    let controller: SheetController

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = GridPalette.surface
        scroll.scrollerStyle = .overlay
        let grid = GridView(controller: controller)
        controller.grid = grid
        scroll.documentView = grid
        DispatchQueue.main.async { grid.focus() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let grid = scroll.documentView as? GridView else { return }
        if grid.controller !== controller {
            grid.controller = controller
            controller.grid = grid
            grid.reloadLayout()
        }
    }
}
