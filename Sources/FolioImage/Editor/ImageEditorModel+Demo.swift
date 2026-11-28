#if DEBUG
    import SwiftUI

    extension ImageEditorModel {
        /// Development aid for `scripts/snapshot.sh`: `FOLIO_IMAGE_DEMO=crop|filters|markup|edited|layers|selection|tone`
        /// puts the editor in that state so each screen can be checked without a mouse.
        func applyDemoStateIfRequested() {
            guard let demo = ProcessInfo.processInfo.environment["FOLIO_IMAGE_DEMO"] else { return }
            let size = source.pixelSize
            let w = size.width, h = size.height
            switch demo {
            case "crop":
                tab = .crop
                commit("Demo") {
                    $0.crop = CGRect(x: 0.1, y: 0.12, width: 0.7, height: 0.72); $0.straighten = 4
                }
            case "filters":
                tab = .filters
                commit("Demo") {
                    $0.filter = .chrome; $0.filterStrength = 0.8
                }
            case "markup":
                tab = .markup
                commit("Demo") {
                    $0.markup = [
                        MarkupItem(
                            kind: .arrow, points: [CGPoint(x: w * 0.55, y: h * 0.75), CGPoint(x: w * 0.42, y: h * 0.66)], color: .red,
                            lineWidth: w / 200),
                        MarkupItem(
                            kind: .ellipse, points: [CGPoint(x: w * 0.63, y: h * 0.15), CGPoint(x: w * 0.82, y: h * 0.45)],
                            color: RGBA(red: 1, green: 0.8, blue: 0), lineWidth: w / 250),
                        MarkupItem(
                            kind: .text, points: [CGPoint(x: w * 0.56, y: h * 0.78)], color: .white, lineWidth: 0, text: "Sunset here",
                            fontSize: w / 30),
                    ]
                }
                selectedMarkupID = recipe.markup.last?.id
            case "popovers":
                // Popovers are separate windows the snapshot hook doesn't capture; draw them.
                guard let dir = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT_DIR"] else { return }
                let dark = ProcessInfo.processInfo.environment["FOLIO_APPEARANCE"] == "dark"
                let views: [(String, AnyView)] = [
                    ("info", AnyView(InfoPopover(model: self))), ("export", AnyView(ExportPopover(model: self))),
                ]
                for (name, view) in views {
                    let renderer = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light))
                    renderer.scale = 2
                    if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                        let png = rep.representation(using: .png, properties: [:])
                    {
                        try? png.write(to: URL(fileURLWithPath: dir).appending(path: "popover-\(name)-\(dark ? "dark" : "light").png"))
                    }
                }
            case "layers":
                tab = .layer
                let shape = Layer(
                    name: "Badge",
                    content: .shape(
                        ShapeSpec(
                            geometry: .ellipse(CGRect(x: w * 0.08, y: h * 0.1, width: w * 0.22, height: w * 0.22)),
                            fill: .solid(RGBA(red: 0.02, green: 0.52, blue: 0.97)))))
                var text = Layer(
                    name: "Title",
                    content: .text(TextSpec(runs: [TextRun(text: "Folio", fontName: "Helvetica-Bold", size: w / 9, color: .white)])))
                text.transform = CGAffineTransform(translationX: w * 0.5, y: h * 0.62)
                var glow = Layer(name: "Warm light", content: .fill(.solid(RGBA(red: 1, green: 0.6, blue: 0.2))))
                glow.blend = .softLight
                glow.opacity = 0.45
                commit("Demo") { $0.layers = [glow, shape, text]; $0.guides = [Guide(axis: .horizontal, position: h * 0.62)] }
                layerState.selectedID = text.id
                showRulers = true
            case "selection":
                tool = .select
                selectionState.spec = SelectionSpec(.ellipse(CGRect(x: w * 0.25, y: h * 0.2, width: w * 0.5, height: h * 0.6)))
                    .adding(.rect(CGRect(x: w * 0.05, y: h * 0.05, width: w * 0.2, height: h * 0.2)))
            case "tone":
                tab = .tone
                tool = .eyedropper
                commit("Demo") {
                    $0.tone.curves.rgb = [CGPoint(x: 0.25, y: 0.2), CGPoint(x: 0.75, y: 0.82)]
                    $0.tone.hsl[.blue] = HSLShift(hue: 0, saturation: 30, luminance: -10)
                }
            case "cutout":
                toggleRemoveBackground()
            case "edited":
                commit("Demo") {
                    $0.adjustments[.exposure] = 25; $0.adjustments[.warmth] = 40; $0.adjustments[.vignette] = 40
                }
            default:
                break
            }
        }
    }
#endif
