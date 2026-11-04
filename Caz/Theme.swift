import SwiftUI
import UIKit

// Colours, metrics and small building blocks. They follow Dopamine's interface
// (DOGlobalAppearance, DOThemeManager, Themes.plist) with a yellow theme taken from Caz's icon.

enum Theme {
    /// Dopamine tints its panels with a dark tone of the theme colour at partial opacity.
    /// For Caz's yellow that's a deep amber.
    static let menu = Color(red: 61 / 255.0, green: 38 / 255.0, blue: 0 / 255.0).opacity(0.55)
    /// Settings, Credits and the other windows.
    static let window = Color(red: 38 / 255.0, green: 24 / 255.0, blue: 0 / 255.0).opacity(0.72)
    /// The icon's gold, used for switches.
    static let accent = Color(red: 255 / 255.0, green: 178 / 255.0, blue: 30 / 255.0)
    static let separator = Color(white: 0.6).opacity(0.3)
    /// Dopamine draws button titles and icons in white at 75%.
    static let foreground = Color.white.opacity(0.75)
    static let secondary = Color.white.opacity(0.8)
    static let failure = Color(red: 1.0, green: 0.62, blue: 0.56)
}

enum Metrics {
    static let padding: CGFloat = 30            // UI_PADDING
    static let innerPadding: CGFloat = 20       // UI_INNER_PADDING
    static let innerPaddingTiny: CGFloat = 10   // UI_INNER_PADDING_TINY
    static let innerTopPadding: CGFloat = 5     // UI_INNER_TOP_PADDING
    static let modalPadding: CGFloat = 30       // UI_MODAL_PADDING
    static let iPadMaxWidth: CGFloat = 600      // UI_IPAD_MAX_WIDTH

    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    static var safeTop: CGFloat { keyWindow?.safeAreaInsets.top ?? 47 }

    static var isHomeButtonDevice: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && (keyWindow?.safeAreaInsets.bottom ?? 34) == 0
    }

    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    static func isSmall(_ height: CGFloat) -> Bool { height < 568 + 50 }

    /// UI_ACTION_HEIGHT, UI_ACTION_HEIGHT_HOME_BTN, UI_ACTION_HEIGHT_TINY
    static func actionHeight(_ height: CGFloat) -> CGFloat {
        if isSmall(height) { return 52 }
        return isHomeButtonDevice ? 65 : 73
    }
}

/// A plain button that dims while pressed, like UIButtonConfiguration.plain.
struct MenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.45 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// The yellow backdrop. It dims to 40% while a window is open, like Dopamine's.
struct Backdrop: View {
    var dimmed: Bool

    var body: some View {
        Color.black
            .overlay {
                Image("Backdrop")
                    .resizable()
                    .scaledToFill()
                    .opacity(dimmed ? 0.4 : 1)
                    .animation(.easeInOut(duration: 0.3), value: dimmed)
            }
            .clipped()
            .ignoresSafeArea()
    }
}

extension View {
    /// Rows in a window: no cell background and no separators, as in Dopamine's lists.
    func windowRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    func windowList() -> some View {
        self
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 48)
            .tint(Theme.accent)
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
