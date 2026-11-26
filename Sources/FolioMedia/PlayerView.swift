import AVKit
import SwiftUI

/// AVPlayerView in SwiftUI. AVKit supplies the native controls, Picture in Picture,
/// AirPlay, chapter navigation, subtitle and audio-track menus, and the trim bar.
struct PlayerView: NSViewRepresentable {
    let controller: MediaController

    func makeNSView(context: Context) -> FolioPlayerView {
        let view = FolioPlayerView()
        view.controller = controller
        view.player = controller.player
        view.controlsStyle = controller.isAudioOnly ? .inline : .floating
        view.allowsPictureInPicturePlayback = !controller.isAudioOnly
        view.showsFullScreenToggleButton = !controller.isAudioOnly
        view.showsTimecodes = true
        view.showsSharingServiceButton = false
        view.setAccessibilityLabel(controller.isAudioOnly ? "Audio player" : "Video player")
        controller.playerView = view
        return view
    }

    func updateNSView(_ view: FolioPlayerView, context: Context) {}
}

/// Adds QuickTime's keyboard shortcuts on top of AVPlayerView's own.
final class FolioPlayerView: AVPlayerView {
    weak var controller: MediaController?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Take keyboard focus when the window opens so space/J/K/L work immediately.
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard let controller, !controller.isTrimming,
              let action = PlayerKey.action(characters: event.charactersIgnoringModifiers ?? "", modifiers: event.modifierFlags)
        else { return super.keyDown(with: event) }
        switch action {
        case .playPause: controller.togglePlay()
        case .shuttle(let key): controller.shuttle(key)
        case .step(let frames): controller.step(by: frames)
        case .markIn: controller.markIn()
        case .markOut: controller.markOut()
        }
    }
}

/// Keyboard map for the player. Pure, so it's testable without a window.
nonisolated enum PlayerKey: Equatable {
    case playPause
    case shuttle(Shuttle.Key)
    case step(Int)
    case markIn, markOut

    static func action(characters: String, modifiers: NSEvent.ModifierFlags) -> PlayerKey? {
        // Leave anything with ⌘, ⌃ or ⌥ to menus and the system.
        guard modifiers.intersection([.command, .control, .option]).isEmpty, let scalar = characters.unicodeScalars.first else { return nil }
        switch Int(scalar.value) {
        case 0x20: return .playPause
        case NSLeftArrowFunctionKey: return .step(-1)
        case NSRightArrowFunctionKey: return .step(1)
        default: break
        }
        switch characters.lowercased() {
        case "j": return .shuttle(.reverse)
        case "k": return .shuttle(.pause)
        case "l": return .shuttle(.forward)
        case "i": return .markIn
        case "o": return .markOut
        default: return nil
        }
    }
}
