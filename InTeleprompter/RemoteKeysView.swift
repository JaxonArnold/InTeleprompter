import SwiftUI
import UIKit

/// Keys understood from hardware keyboards and Bluetooth remotes.
/// Page-turner pedals and scrolling rings pair as plain HID keyboards, so
/// one code path covers pedals, rings, and iPad keyboards alike.
///
/// Note: camera-shutter remotes that emulate the *volume* buttons (and
/// media-button rings) use a different channel entirely — iOS delivers
/// those to the media remote-command center, not as key presses, and
/// there's no reliable way to intercept them while the capture session
/// owns the audio session. Only keyboard-emulating remotes are supported.
enum RemoteKey {
    case playPause        // space
    case recordToggle     // return / enter
    case scrubBack        // left / up / page up
    case scrubForward     // right / down / page down
    case speedDown        // -
    case speedUp          // + or =
    case reset            // home, or ⌘↑
}

/// Invisible first-responder that turns hardware key presses into
/// `RemoteKey` actions. Add it anywhere in the view hierarchy.
struct RemoteKeysView: UIViewRepresentable {
    /// Bump to make the view reclaim key focus, e.g. after a presented
    /// sheet or cover (which may have become first responder) dismisses.
    let reclaimToken: Int
    let onKey: (RemoteKey) -> Void

    func makeUIView(context: Context) -> RemoteKeysUIView {
        let view = RemoteKeysUIView()
        view.onKey = onKey
        return view
    }

    func updateUIView(_ uiView: RemoteKeysUIView, context: Context) {
        uiView.onKey = onKey
        if uiView.lastReclaimToken != reclaimToken {
            uiView.lastReclaimToken = reclaimToken
            if uiView.window != nil, !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
            }
        }
    }
}

final class RemoteKeysUIView: UIControl {
    var onKey: ((RemoteKey) -> Void)?
    var lastReclaimToken = -1

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            if let key = press.key, let remote = Self.map(key: key) {
                onKey?(remote)
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    /// HID usage → action. Matching on key codes (not characters) keeps the
    /// mapping layout-independent, and every mapping the common pedals ship
    /// with is covered: arrows, page up/down, space, and enter.
    private static func map(key: UIKey) -> RemoteKey? {
        if key.modifierFlags.contains(.command), key.keyCode == .keyboardUpArrow {
            return .reset
        }
        switch key.keyCode {
        case .keyboardSpacebar:
            return .playPause
        case .keyboardReturnOrEnter, .keypadEnter:
            return .recordToggle
        case .keyboardLeftArrow, .keyboardUpArrow, .keyboardPageUp:
            return .scrubBack
        case .keyboardRightArrow, .keyboardDownArrow, .keyboardPageDown:
            return .scrubForward
        case .keyboardHyphen, .keypadHyphen:
            return .speedDown
        case .keyboardEqualSign, .keypadPlus, .keypadEqualSign:
            return .speedUp
        case .keyboardHome:
            return .reset
        default:
            return nil
        }
    }
}
