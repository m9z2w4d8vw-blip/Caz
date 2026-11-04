import SwiftUI

enum Theme {
    static let abyss = Color(red: 13 / 255.0, green: 16 / 255.0, blue: 40 / 255.0)     // #0D1028
    static let violet = Color(red: 106 / 255.0, green: 76 / 255.0, blue: 255 / 255.0)  // #6A4CFF
    static let lagoon = Color(red: 34 / 255.0, green: 195 / 255.0, blue: 214 / 255.0)  // #22C3D6
    static let orchid = Color(red: 226 / 255.0, green: 89 / 255.0, blue: 180 / 255.0)  // #E259B4
    static let signal = Color(red: 1.0, green: 107 / 255.0, blue: 107 / 255.0)         // #FF6B6B
    static let sweep = LinearGradient(colors: [lagoon, violet], startPoint: .leading, endPoint: .trailing)
}

/// Deep indigo with three soft glows. Static on purpose: the only motion in Caz is the sweep.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.abyss
            Circle()
                .fill(Theme.violet.opacity(0.55))
                .frame(width: 380, height: 380)
                .blur(radius: 110)
                .offset(x: -130, y: -300)
            Circle()
                .fill(Theme.lagoon.opacity(0.40))
                .frame(width: 320, height: 320)
                .blur(radius: 110)
                .offset(x: 150, y: 60)
            Circle()
                .fill(Theme.orchid.opacity(0.30))
                .frame(width: 300, height: 300)
                .blur(radius: 120)
                .offset(x: -90, y: 380)
        }
        .ignoresSafeArea()
    }
}

struct CategoryRow: View {
    let category: CleanCategory
    let bytes: Int64?
    @Binding var isOn: Bool
    var onDetail: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn ? Theme.lagoon : Color.white.opacity(0.45))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(isOn ? 0.10 : 0.05)))
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text(category.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let bytes {
                Text(CleanerModel.format(bytes))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(bytes > 0 ? 0.95 : 0.35))
            }
            if let onDetail {
                Button(action: onDetail) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 28, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose apps")
            }
            Toggle(category.title, isOn: $isOn)
                .labelsHidden()
                .tint(Theme.lagoon)
        }
        .padding(.vertical, 11)
    }
}

/// The one bold element: a pill that fills left to right as each category finishes.
struct SweepButton: View {
    @ObservedObject var model: CleanerModel

    var body: some View {
        Button(action: tap) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                GeometryReader { geo in
                    Capsule()
                        .fill(Theme.sweep)
                        .frame(width: max(geo.size.height, geo.size.width * CGFloat(fill)))
                        .opacity(fill > 0 ? 1 : 0)
                }
                HStack(spacing: 10) {
                    if model.isBusy {
                        ProgressView().tint(.white)
                    }
                    Text(title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
            }
            .frame(height: 60)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .contentShape(Capsule())
            .animation(.easeInOut(duration: 0.35), value: fill)
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
    }

    private var fill: Double {
        switch model.phase {
        case .idle: return 0
        case .scanning, .cleaning: return model.progress
        case .scanned, .done: return 1
        }
    }

    private var title: String {
        switch model.phase {
        case .idle:
            return "Scan"
        case .scanning:
            return "Scanning…"
        case .scanned:
            let bytes = model.selectedBytes
            return bytes > 0 ? "Clean \(CleanerModel.format(bytes))" : "Nothing to clean"
        case .cleaning:
            return "Cleaning…"
        case .done:
            return "Scan again"
        }
    }

    private func tap() {
        switch model.phase {
        case .idle, .done: model.scan()
        case .scanned: model.clean()
        case .scanning, .cleaning: break
        }
    }
}

struct LogConsole: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if lines.isEmpty {
                        Text("Tap Scan to measure what can be cleaned.")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.top, 6)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("!") ? Theme.signal : Color.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: lines.count) { _, count in
                guard count > 0 else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
    }
}

struct ProblemBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(Theme.signal)
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.signal.opacity(0.18)))
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
