import SwiftUI
import UIKit

enum CazWindow: Equatable {
    case categories, apps, settings, log, update
}

/// The main screen, laid out like DOMainViewController: a header, the action menu and the big
/// button in one vertical stack, 73% of the screen tall with 30 pt margins.
struct ContentView: View {
    @StateObject private var model = CleanerModel()
    @StateObject private var updater = UpdateModel()
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
        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: updater.isAvailable)
        .onAppear {
            model.onAppear()
            updater.check()
        }
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
            .overlay(alignment: .top) {
                // Dopamine's update button: 30 pt tall, 20 pt above the big button (10 on home-button
                // phones), sliding up 25 pt as it fades in, and hidden while the big button is open.
                if updater.isAvailable {
                    UpdateLinkButton(title: "Update Available", symbol: "arrow.down.circle") {
                        window = .update
                    }
                    .frame(height: 30)
                    .offset(y: -(30 + (Metrics.isHomeButtonDevice ? 10 : 20)))
                    .opacity(expanded ? 0 : 1)
                    .allowsHitTesting(!expanded)
                    .transition(.offset(y: 25).combined(with: .opacity))
                }
            }
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
                .onTapGesture {
                    if window == .update && updater.isBusy { return }   // can't back out mid-update
                    self.window = nil
                    updater.resetIfIdle()
                }
            windowView(window, size: size)
                .frame(width: min(size.width - Metrics.modalPadding * 2, Metrics.iPadMaxWidth),
                       height: size.height * (small ? 0.8 : 0.7))
                .transition(.scale(scale: 0.7).combined(with: .opacity))
        }
        .zIndex(2)
    }

    @ViewBuilder
    private func windowView(_ window: CazWindow, size: CGSize) -> some View {
        switch window {
        case .update:
            UpdateFlowView(updater: updater, screenWidth: size.width) { file, done in
                model.installUpdate(file, completion: done)
            }
        case .categories:
            CategoriesWindow(model: model)
        case .apps:
            AppsWindow(model: model)
        case .settings:
            SettingsWindow(model: model, openLog: { self.window = .log })
        case .log:
            LogWindow(model: model, onBack: { self.window = .settings })
        }
    }

    // MARK: - Actions

    private var menuItems: [MenuItem] {
        [
            MenuItem(id: "settings", title: "Settings", symbol: "gearshape",
                     chevron: true) { window = .settings },
            MenuItem(id: "scan", title: "Scan", symbol: "magnifyingglass",
                     enabled: !model.isBusy) { model.scan() },
            MenuItem(id: "apps", title: "App Caches", symbol: "square.stack.3d.up",
                     chevron: true, enabled: !model.isBusy) { window = .apps },
            MenuItem(id: "categories", title: "Categories", symbol: "checklist",
                     chevron: true, enabled: !model.isBusy) { window = .categories },
        ]
    }

}
