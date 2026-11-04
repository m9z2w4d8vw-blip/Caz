import SwiftUI
import UIKit

enum CazWindow: Equatable {
    case categories, apps, settings, log, credits, license
}

/// The main screen, laid out like DOMainViewController: a header, the action menu and the big
/// button in one vertical stack, 73% of the screen tall with 30 pt margins.
struct ContentView: View {
    @StateObject private var model = CleanerModel()
    @State private var window: CazWindow? = nil
    @Namespace private var actionSpace

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Backdrop(dimmed: window != nil)
                mainStack(size: geo.size)
                if model.sheetVisible {
                    expandedSheet(size: geo.size)
                }
                if let window {
                    windowLayer(window, size: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.75, dampingFraction: 0.9), value: model.sheetVisible)
        .animation(.spring(response: 0.6, dampingFraction: 0.9), value: window)
        .sensoryFeedback(.impact(weight: .light), trigger: model.completedSteps)
        .sensoryFeedback(.success, trigger: model.successCount)
        .onAppear { model.onAppear() }
    }

    // MARK: - Main stack

    private func mainStack(size: CGSize) -> some View {
        let expanded = model.sheetVisible
        let windowOpen = window != nil
        let small = Metrics.isSmall(size.height)
        let stackHeight = size.height * (Metrics.isHomeButtonDevice ? 0.78 : 0.73)
        let stackWidth = Metrics.isPad ? min(size.width * 0.8, Metrics.iPadMaxWidth) : size.width - Metrics.padding * 2
        let statusOffset = max(15, Metrics.safeTop - 20)

        return VStack(spacing: 0) {
            HeaderView(subtitle: model.headerSubtitle,
                       detail: model.headerDetail,
                       detailIsWarning: model.problem != nil)
                .offset(y: expanded ? -25 : 0)
            Spacer(minLength: 12)
            ActionMenu(items: menuItems,
                       rowHeight: Metrics.actionHeight(size.height),
                       innerPadding: small ? Metrics.innerPaddingTiny : Metrics.innerPadding)
                .scaleEffect(expanded ? 0.6 : 1)
                .offset(y: expanded ? -75 : 0)
                .opacity(expanded ? 0 : 1)
                .allowsHitTesting(!expanded)
            Spacer(minLength: 12)
            ZStack {
                if !expanded {
                    ActionButton(title: model.cleanTitle,
                                 symbol: "trash",
                                 enabled: model.canClean) {
                        model.clean()
                    }
                    .matchedGeometryEffect(id: "action", in: actionSpace)
                }
            }
            .frame(height: 60)
        }
        .frame(width: stackWidth, height: stackHeight)
        .position(x: size.width / 2, y: size.height / 2 + statusOffset)
        .scaleEffect(windowOpen ? 0.9 : 1)
        .opacity(windowOpen ? 0 : 1)
        .allowsHitTesting(!windowOpen)
    }

    // MARK: - Expanded button (the log)

    private func expandedSheet(size: CGSize) -> some View {
        let top = size.height * 0.26 + 35
        let visible = size.height - top
        return LogSheet(model: model, visibleHeight: visible)
            .matchedGeometryEffect(id: "action", in: actionSpace)
            .frame(width: size.width, height: visible + 100)
            .position(x: size.width / 2, y: top + (visible + 100) / 2)
            .zIndex(1)
    }

    // MARK: - Windows

    private func windowLayer(_ window: CazWindow, size: CGSize) -> some View {
        let small = Metrics.isSmall(size.height)
        return ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { self.window = nil }
            windowView(window)
                .frame(width: min(size.width - Metrics.modalPadding * 2, Metrics.iPadMaxWidth),
                       height: size.height * (small ? 0.8 : 0.7))
                .transition(.scale(scale: 0.7).combined(with: .opacity))
        }
        .zIndex(2)
    }

    @ViewBuilder
    private func windowView(_ window: CazWindow) -> some View {
        switch window {
        case .categories:
            CategoriesWindow(model: model)
        case .apps:
            AppsWindow(model: model)
        case .settings:
            SettingsWindow(model: model, openLog: { self.window = .log })
        case .log:
            LogWindow(model: model, onBack: { self.window = .settings })
        case .credits:
            CreditsWindow(openLicense: { self.window = .license })
        case .license:
            LicenseWindow(onBack: { self.window = .credits })
        }
    }

    // MARK: - Actions

    private var menuItems: [MenuItem] {
        [
            MenuItem(id: "categories", title: "Categories", symbol: "checklist",
                     chevron: true, enabled: !model.isBusy) { window = .categories },
            MenuItem(id: "apps", title: "App Caches", symbol: "square.stack.3d.up",
                     chevron: true, enabled: !model.isBusy) { window = .apps },
            MenuItem(id: "settings", title: "Settings", symbol: "gearshape",
                     chevron: true) { window = .settings },
            MenuItem(id: "scan", title: "Scan", symbol: "magnifyingglass",
                     enabled: !model.isBusy) { model.scan() },
            MenuItem(id: "credits", title: "Credits", symbol: "info.circle",
                     chevron: true) { window = .credits },
        ]
    }

}
