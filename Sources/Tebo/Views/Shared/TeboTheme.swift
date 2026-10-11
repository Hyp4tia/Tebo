import AppKit
import Observation
import SwiftUI

// MARK: - Tebo visual language
// One place for the whole look: cards, tiles, badges, section headers, paths, empty states.
// Adapted (not copied) from studying Mole's own Mac app: warm canvas, elevated cards, big
// numbers with small units, hairline separators, real data only. System accent stays the
// user's own: selection and primary actions use it, nothing else invents colour.

enum Tebo {
    static let cardRadius: CGFloat = 12
    static let rowSpacing: CGFloat = 10
    static let gutter: CGFloat = 16
}

/// One formatter for every size the UI shows, so numbers are comparable across tabs.
enum TeboBytes {
    static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: Card surface

extension View {
    /// Elevated card surface: fills the content area of a section without a table look.
    func teboCard(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Tebo.cardRadius, style: .continuous)
                    .fill(TeboPalette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tebo.cardRadius, style: .continuous)
                    .strokeBorder(TeboPalette.line, lineWidth: 1)
            )
    }
}

/// Canvas colour for a tab's scroll content, so cards read as raised without a heavy shadow.
struct TeboCanvas: ViewModifier {
    func body(content: Content) -> some View {
        content.background(TeboPalette.canvas)
    }
}

extension View {
    func teboCanvas() -> some View { modifier(TeboCanvas()) }
}

// MARK: Navigation pills

/// The one pill style for the window's navigation and the Toolbox's sub-tools, so a pill means
/// the same thing and behaves the same way wherever it appears.
struct TeboPill: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    var helpText: String? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.primary.opacity(isActive ? 0.12 : 0), lineWidth: 1)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(helpText ?? title)
        .onHover { isHovered = $0 }
    }

    private var fill: Color {
        if isActive { return TeboPalette.selection }
        return isHovered ? TeboPalette.selection.opacity(0.5) : .clear
    }
}

// Reference-driven desktop shell. Literal colors belong here, never in individual tabs.
enum TeboPalette {
    static let referenceWidth: CGFloat = 1352
    static let sidebarWidth: CGFloat = 284
    static let inspectorWidth: CGFloat = 352
    static let canvas = Color(red: 0.964, green: 0.952, blue: 0.940)
    static let sidebar = Color(red: 0.910, green: 0.891, blue: 0.868)
    static let inspector = Color(red: 0.953, green: 0.941, blue: 0.925)
    static let card = Color(red: 0.981, green: 0.975, blue: 0.966)
    static let ink = Color(red: 0.098, green: 0.118, blue: 0.145)
    static let secondary = Color(red: 0.390, green: 0.402, blue: 0.423)
    static let muted = Color(red: 0.555, green: 0.551, blue: 0.549)
    static let line = Color(red: 0.884, green: 0.867, blue: 0.850)
    static let selection = Color(red: 0.865, green: 0.845, blue: 0.818)
    static let halo = Color(red: 0.909, green: 0.895, blue: 0.875)
    static let mint = Color(red: 0.040, green: 0.665, blue: 0.569)
    static let blue = Color(red: 0.204, green: 0.443, blue: 0.954)
    static let purple = Color(red: 0.477, green: 0.224, blue: 0.858)
    static let violet = Color(red: 0.433, green: 0.232, blue: 0.958)
    static let orange = Color(red: 0.992, green: 0.440, blue: 0.143)
}

@Observable @MainActor
final class WorkspaceActivity {
    var isScanning = false
    var lastScan: Date?
    var scanDuration: TimeInterval?
    var trashedBytes: Int64 = 0
    var trashedCount = 0
    var groupsByTab: [String: [UUID: String]] = [:]
    var detailsByTab: [String: [UUID: CzkawkaItemDetail]] = [:]

    var durationText: String {
        guard let scanDuration else { return "\u{2013}" }
        return String(format: "%.1f s", scanDuration)
    }
    func recordScan(started: Date) {
        let finished = Date.now
        scanDuration = finished.timeIntervalSince(started)
        lastScan = finished
        isScanning = false
    }
    func recordRemoval(_ report: DeleteReport) {
        trashedBytes += report.freedBytes
        trashedCount += report.trashedCount
    }
}

private struct WorkspaceSearchKey: EnvironmentKey {
    static let defaultValue = ""
}
extension EnvironmentValues {
    var workspaceSearch: String {
        get { self[WorkspaceSearchKey.self] }
        set { self[WorkspaceSearchKey.self] = newValue }
    }
}

struct TeboLogo: View {
    let size: CGFloat
    private static var image: NSImage? {
        var candidates = [Bundle.main.url(forResource: "TeboLogo", withExtension: "png")]
        #if SWIFT_PACKAGE
        candidates.append(Bundle.module.url(forResource: "TeboLogo", withExtension: "png", subdirectory: "Resources"))
        #endif
        return candidates.compactMap { $0 }.compactMap { NSImage(contentsOf: $0) }.first
    }
    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Tebo logo")
    }
}

struct CategorySymbol: View {
    let page: WorkspacePage
    var body: some View {
        ZStack {
            Circle().fill(page.tint.opacity(page == .archives ? 0.09 : 0.14))
            if page == .applications {
                ApplicationMark().stroke(page.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 21, height: 23)
            } else {
                Image(systemName: page == .downloads ? "arrow.down.circle.fill" : page == .archives ? "bag" : page.symbol)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(page.tint)
                    .symbolVariant(page == .largeFiles || page == .duplicates ? .fill : .none)
            }
        }
        .accessibilityHidden(true)
    }
}

struct SidebarSymbol: View {
    let page: WorkspacePage
    var body: some View {
        if page == .applications {
            ApplicationMark().stroke(TeboPalette.ink, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .frame(width: 17, height: 19)
        } else {
            Image(systemName: page == .archives ? "bag" : page.symbol).font(.system(size: 18))
        }
    }
}
private struct ApplicationMark: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.width * 0.58, y: r.height * 0.10))
            p.addLine(to: CGPoint(x: r.width * 0.10, y: r.height * 0.90))
            p.move(to: CGPoint(x: r.width * 0.38, y: r.height * 0.10))
            p.addLine(to: CGPoint(x: r.width * 0.90, y: r.height * 0.90))
            p.move(to: CGPoint(x: r.width * 0.08, y: r.height * 0.65))
            p.addLine(to: CGPoint(x: r.width * 0.91, y: r.height * 0.65))
        }
    }
}

struct ScanRing: View {
    let isComplete: Bool
    var body: some View {
        ZStack {
            Circle().stroke(TeboPalette.ink.opacity(0.16), lineWidth: 5)
            Circle().trim(from: 0, to: isComplete ? 0.98 : 0.72)
                .stroke(TeboPalette.ink, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(3).accessibilityHidden(true)
    }
}

struct TeboPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 21).frame(height: 42)
            .background {
                Capsule().fill(LinearGradient(colors: [TeboPalette.ink.opacity(0.93), TeboPalette.ink],
                                               startPoint: .top, endPoint: .bottom))
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct FocusCard: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14).fill(TeboPalette.selection.opacity(0.25))
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "sparkle").font(.system(size: 15))
                Text("Less clutter,\nmore focus.").font(.system(size: 14)).lineSpacing(3)
            }
            .padding(26)
            VStack {
                Spacer()
                ZStack {
                    FocusWave(upper: true).fill(TeboPalette.selection.opacity(0.30))
                    FocusWave(upper: false).fill(TeboPalette.selection.opacity(0.40))
                }
                .frame(height: 66)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
private struct FocusWave: Shape {
    let upper: Bool
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        return Path { p in
            p.move(to: CGPoint(x: 0, y: h * 0.95))
            p.addCurve(to: CGPoint(x: w * 0.37, y: h * 0.72),
                       control1: CGPoint(x: w * 0.19, y: h), control2: CGPoint(x: w * 0.18, y: h * 0.4))
            p.addCurve(to: CGPoint(x: w * 0.75, y: upper ? h * 0.10 : h * 0.58),
                       control1: CGPoint(x: w * 0.57, y: h), control2: CGPoint(x: w * 0.64, y: upper ? -h * 0.10 : h * 0.30))
            p.addCurve(to: CGPoint(x: w, y: upper ? h * 0.63 : h * 0.96),
                       control1: CGPoint(x: w * 0.88, y: upper ? h * 0.12 : h * 0.53), control2: CGPoint(x: w * 0.89, y: h * 0.85))
            p.addLine(to: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: 0, y: h))
            p.closeSubpath()
        }
    }
}

// MARK: Numbers and text

/// Size or count with tabular figures so columns line up down a list.
struct TeboNumber: View {
    let text: String
    var font: Font = .callout
    var emphasis: Bool = false

    var body: some View {
        Text(text)
            .font(font)
            .monospacedDigit()
            .fontWeight(emphasis ? .semibold : .regular)
            .foregroundStyle(emphasis ? .primary : .secondary)
            .lineLimit(1)
    }
}

/// A path, monospaced and middle-truncated: the tail (the actual file) is what matters.
struct TeboPath: View {
    let path: String
    var abbreviated: Bool = true

    var body: some View {
        Text(abbreviated ? Self.abbreviate(path) : path)
            .font(.caption)
            .monospaced()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }

    /// ~/Documents instead of /Users/someone/Documents, like every other Mac app.
    static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: Tiles and badges

/// Stat tile: bold value, small unit, quiet label, tinted symbol. Nothing decorative.
struct StatTile: View {
    let label: String
    let value: String
    var unit: String? = nil
    let systemImage: String
    var tint: Color = .secondary
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                if let unit {
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .teboCard(padding: 12)
    }
}

/// Small state pill: "needs admin", "protected", "in use".
struct TeboBadge: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            }
            Text(text).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: Section headers

/// Group header above rows: icon, name, count, optional size and trailing content.
struct TeboSectionHeader<Trailing: View>: View {
    let title: String
    var systemImage: String? = nil
    var count: Int? = nil
    var sizeText: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(title).font(.subheadline.weight(.semibold))
            if let count {
                Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if let sizeText {
                Text("· \(sizeText)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 2)
    }
}

extension TeboSectionHeader where Trailing == EmptyView {
    init(title: String, systemImage: String? = nil, count: Int? = nil, sizeText: String? = nil) {
        self.init(title: title, systemImage: systemImage, count: count, sizeText: sizeText) { EmptyView() }
    }
}

// MARK: Empty state

/// Replaces paragraphs of explanation: one icon, one sentence, one action.
struct TeboEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
