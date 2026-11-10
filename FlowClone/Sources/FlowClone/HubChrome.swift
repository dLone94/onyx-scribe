import SwiftUI

// MARK: - Hub chrome
//
// The shared shell every Hub page speaks through: one set of margins, one
// content measure, one header treatment, one row vocabulary. Pages compose
// these instead of inventing their own paddings and panels, which is what
// makes six pages read as one product.

/// Layout constants shared by every Hub page.
enum HubMetrics {
    static let pageHPad: CGFloat = 32
    static let pageTopPad: CGFloat = 28
    static let pageBottomPad: CGFloat = 36
    /// The reading measure. Wide editors (Scratchpad) may exceed it; prose and
    /// settings never should.
    static let contentMaxWidth: CGFloat = 760
    static let sectionSpacing: CGFloat = 26
    static let rowCorner: CGFloat = 8
}

/// Page title + optional subtitle. Fraunces carries the title (the page's one
/// editorial moment); everything after it is SF Pro.
struct PageHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(FlowType.title)
                .foregroundStyle(FlowColor.ink)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(FlowColor.inkSoft)
            }
        }
    }
}

/// Standard scrollable page: header + sections in a single measured column.
struct PageScaffold<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HubMetrics.sectionSpacing) {
                PageHeader(title: title, subtitle: subtitle)
                content
            }
            .padding(.horizontal, HubMetrics.pageHPad)
            .padding(.top, HubMetrics.pageTopPad)
            .padding(.bottom, HubMetrics.pageBottomPad)
            .frame(maxWidth: HubMetrics.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A titled section: SF semibold header, optional caption, content below.
/// Sections separate by whitespace — not by wrapping everything in a panel.
struct HubSection<Content: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FlowColor.ink)
                    .accessibilityAddTraits(.isHeader)
                if let caption {
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundStyle(FlowColor.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A grouped list surface: rows divided by hairlines inside ONE quiet panel.
/// Replaces the per-row cards (and the nested-card look they created).
struct RowGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .edgeLit(cornerRadius: 10, fill: FlowColor.rowFill)
    }
}

/// The hairline between rows inside a RowGroup.
struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(FlowColor.hairline.opacity(0.35))
            .frame(height: 1)
            .padding(.leading, 12)
    }
}

/// One row inside a RowGroup: consistent height and padding.
struct HubRow<Content: View>: View {
    var alignment: VerticalAlignment = .center
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: alignment, spacing: 8) { content }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Status dot + label. State is carried by the WORD, the color only reinforces
/// it (never color alone).
struct StatusLine: View {
    enum Kind { case ok, warn }
    let kind: Kind
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(kind == .ok ? FlowColor.success : FlowColor.amber)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(FlowColor.ink.opacity(0.92))
        }
    }
}

extension View {
    /// A quiet grouped container — panel fill + hairline, no shadow, no glow.
    /// The only sanctioned "card": used where content genuinely needs a frame
    /// (a chart, an editor), never as decoration.
    func quietPanel(cornerRadius: CGFloat = 12) -> some View {
        edgeLit(cornerRadius: cornerRadius, fill: FlowColor.panel.opacity(0.72))
    }

    /// The Edge-Lit surface (DESIGN.md §4, "lit, not lifted"): a flat fill
    /// whose TOP edge catches indigo light — a gradient hairline that fades
    /// down the sides, plus a faint wash of the same light just inside the
    /// edge. No shadow, no glow: presence comes from where the light lands.
    func edgeLit(cornerRadius: CGFloat, fill: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(
            shape.fill(fill)
                .overlay(shape.fill(LinearGradient(
                    colors: [FlowColor.indigoBright.opacity(0.07), .clear],
                    startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.55))))
        )
        .overlay(
            shape.strokeBorder(LinearGradient(
                stops: [.init(color: FlowColor.crystal.opacity(0.34), location: 0),
                        .init(color: Color.white.opacity(0.09), location: 0.45),
                        .init(color: Color.white.opacity(0.035), location: 1)],
                startPoint: .top, endPoint: .bottom), lineWidth: 1)
            .allowsHitTesting(false)
        )
    }
}

/// Secondary action as a quiet capsule (DESIGN.md §5: capsule shape, quiet by
/// design) — replaces stock grey push buttons on the dark canvas. Destructive
/// roles stay quiet too; their confirmation dialog carries the weight.
struct QuietCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(FlowColor.ink.opacity(isEnabled ? 0.92 : 0.38))
            .padding(.horizontal, 13)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.13 : 0.065)))
            .overlay(Capsule().strokeBorder(LinearGradient(
                colors: [FlowColor.crystal.opacity(isEnabled ? 0.30 : 0.12), Color.white.opacity(0.05)],
                startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

/// The keyboard-shortcut reminder, set in the machine's own voice (mono = what
/// the machine hears; the established Typography-Is-The-Icon rule).
struct KeycapHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(FlowColor.indigoBright)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(FlowColor.indigo.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(FlowColor.indigo.opacity(0.35), lineWidth: 1)
            )
    }
}
