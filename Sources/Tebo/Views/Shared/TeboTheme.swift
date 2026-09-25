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
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tebo.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
    }
}

/// Canvas colour for a tab's scroll content, so cards read as raised without a heavy shadow.
struct TeboCanvas: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Color(nsColor: .windowBackgroundColor))
    }
}

extension View {
    func teboCanvas() -> some View { modifier(TeboCanvas()) }
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
