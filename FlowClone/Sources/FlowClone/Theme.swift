import SwiftUI
import AppKit
import CoreText

// MARK: - FlowClone design tokens
//
// The single source of truth for the redesign's colour, type and motion. Before
// this file, `flowAccent` was redefined in HubView and PillView and the semantic
// reds/greens lived inline in PillView; those now resolve here so every surface
// speaks the same language.
//
// Register: *product* (design serves the tool). Colour is Restrained by default;
// the Insights home and onboarding earn Committed (indigo + amber carrying the
// surface). Fraunces is display-only — headings and hero copy — never labels,
// buttons or data, which stay SF Pro.

// MARK: Colour

enum FlowColor {
    /// Primary brand indigo — the app-icon gradient anchor (#5957D6).
    static let indigo      = Color(red: 0.35,  green: 0.34,  blue: 0.84)
    /// Darker indigo for text-on-light and pressed states (passes AA on white).
    static let indigoDeep  = Color(red: 0.235, green: 0.225, blue: 0.60)
    /// Very light indigo wash for selected/tinted fills.
    static let indigoWash  = Color(red: 0.35,  green: 0.34,  blue: 0.84).opacity(0.10)

    /// Secondary warm accent — honey amber. Graphic/accent use only; it does not
    /// pass body-text contrast on light, so pair with `amberInk` for text.
    static let amber       = Color(red: 0.92,  green: 0.64,  blue: 0.24)
    /// Amber dark enough for text/eyebrow use on a light canvas (~AA).
    static let amberInk    = Color(red: 0.62,  green: 0.40,  blue: 0.06)

    /// Semantic signals (kept distinct from indigo and amber on purpose).
    static let recording   = Color(red: 1.0,   green: 0.27,  blue: 0.23)
    static let success     = Color(red: 0.20,  green: 0.78,  blue: 0.35)

    /// Bright indigo for accents and figures on the DARK canvas (it glows;
    /// the deeper `indigo`/`indigoDeep` are for fills and light surfaces).
    static let indigoBright = Color(red: 0.58,  green: 0.55,  blue: 1.0)
    /// Crystal (#CCC9FF): the light-struck extreme — edge hairlines only.
    static let crystal     = Color(red: 0.80,  green: 0.79,  blue: 1.0)

    /// The Hub is a dark, glowing editorial surface. Canvas is a deep near-black
    /// with an indigo cast (never flat black); ink is near-white; panels lift a
    /// step off the canvas.
    static let ink         = Color(red: 0.95,  green: 0.95,  blue: 0.98)
    static let inkSoft     = Color(red: 0.63,  green: 0.64,  blue: 0.73)
    static let canvas      = Color(red: 0.055, green: 0.055, blue: 0.085)
    static let panel       = Color(red: 0.105, green: 0.105, blue: 0.150)
    static let hairline    = Color(red: 0.24,  green: 0.24,  blue: 0.32)

    /// The floating pill capsule stays dark regardless of system theme.
    static let pillInk     = Color(red: 0.11,  green: 0.11,  blue: 0.12)

    /// Selected / interactive fill — dark blackberry purple (#332B57). Quiet
    /// enough to sit in the sidebar all day; the bright violet stays reserved
    /// for focus, recording, and genuinely primary actions.
    static let blackberry  = Color(red: 0.20,  green: 0.169, blue: 0.341)
    /// Subtle hover wash on dark surfaces.
    static let hover       = Color.white.opacity(0.05)
    /// Recessed row fill used inside grouped lists (never a card on a card).
    static let rowFill     = Color.white.opacity(0.04)
}

/// Back-compat alias: existing views reference `flowAccent`. New code uses
/// `FlowColor.indigo`.
let flowAccent = FlowColor.indigo

/// Tracks whether any brand window (Hub, onboarding) is actually visible on
/// screen. Ambient TimelineViews (aurora, mascot) fall back to a static frame
/// while nothing is visible, so a retained-but-closed or fully occluded window
/// costs zero CPU. Deterministic — never rely on SwiftUI pausing for us.
final class AmbientGate: ObservableObject {
    static let shared = AmbientGate()
    @Published private(set) var active = false
    private var visible = Set<Int>()

    func set(_ windowNumber: Int, visible v: Bool) {
        if v { visible.insert(windowNumber) } else { visible.remove(windowNumber) }
        let now = !visible.isEmpty
        if now != active { active = now }
    }

    /// Register a window: visible now, updated on occlusion changes, removed
    /// on close.
    static func track(_ w: NSWindow) {
        shared.set(w.windowNumber, visible: true)
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main
        ) { note in
            guard let win = note.object as? NSWindow else { return }
            shared.set(win.windowNumber, visible: win.occlusionState.contains(.visible))
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main
        ) { note in
            guard let win = note.object as? NSWindow else { return }
            shared.set(win.windowNumber, visible: false)
        }
    }
}

/// The Hub's atmospheric backdrop: a deep near-black base lit by a soft indigo
/// aurora up top and a faint amber warmth below. This is what makes the dark Hub
/// *glow* rather than sit flat. Cheap enough (two blurred ellipses) for a window.
struct FlowCanvasBackground: View {
    @ObservedObject private var motion = MotionPreferences.shared
    @ObservedObject private var gate = AmbientGate.shared

    var body: some View {
        Group {
            if motion.reduceMotion || !gate.active {
                aurora(t: 0)
            } else {
                // ~10fps ambient drift — imperceptibly different from 15 for
                // motion this slow, two-thirds the render cost.
                TimelineView(.animation(minimumInterval: 1.0 / 10)) { ctx in
                    aurora(t: ctx.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func aurora(t: Double) -> some View {
        // Two light pools that slowly wander — the surface breathes.
        let dx1 = 46 * sin(t * 0.05),  dy1 = 34 * cos(t * 0.043)
        let dx2 = 54 * cos(t * 0.037), dy2 = 40 * sin(t * 0.048)
        return ZStack {
            FlowColor.canvas
            Ellipse().fill(FlowColor.indigo.opacity(0.42))
                .frame(width: 700, height: 440).blur(radius: 150)
                .offset(x: -150 + dx1, y: -250 + dy1)
            // A second, cooler pool keeps the right side of wide pages from
            // falling to flat black.
            Ellipse().fill(FlowColor.indigoBright.opacity(0.10))
                .frame(width: 520, height: 320).blur(radius: 160)
                .offset(x: 380 - dx2, y: -40 + dy1)
            Ellipse().fill(FlowColor.amber.opacity(0.09))
                .frame(width: 520, height: 340).blur(radius: 150)
                .offset(x: 320 + dx2, y: 360 + dy2)
        }
        .drawingGroup()
    }
}

/// Luxury surface: panel fill, a light-catching gradient hairline on the top
/// edge, and a soft float shadow so cards read as lifted off the dark canvas.
struct LuxuryCard: ViewModifier {
    var cornerRadius: CGFloat = 16
    var glow: Color? = nil
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(FlowColor.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.02)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1)
                )
                .shadow(color: (glow ?? .black).opacity(glow == nil ? 0.35 : 0.28),
                        radius: 18, y: 8)
        )
    }
}

extension View {
    func luxuryCard(cornerRadius: CGFloat = 16, glow: Color? = nil) -> some View {
        modifier(LuxuryCard(cornerRadius: cornerRadius, glow: glow))
    }
}

// MARK: Brandmark — the Onyx Cat

/// A single filled facet from a list of normalised points.
private struct Facet: Shape {
    let pts: [(Double, Double)]
    func path(in r: CGRect) -> Path {
        var path = Path()
        for (i, q) in pts.enumerated() {
            let c = CGPoint(x: r.minX + r.width * q.0, y: r.minY + r.height * q.1)
            if i == 0 { path.move(to: c) } else { path.addLine(to: c) }
        }
        path.closeSubpath()
        return path
    }
}

/// The macOS app icon — the Onyx Cat mascot on a dark squircle. Rendered
/// offscreen to a PNG by `--icon-snapshot`, then packed into AppIcon.icns.
/// Deterministic (blink held open).
struct AppIconView: View {
    var size: CGFloat = 1024
    var body: some View {
        let tile = size * 0.82
        let medallion = tile * 0.72
        let glyph = tile * 0.58
        ZStack {
            RoundedRectangle(cornerRadius: tile * 0.2237, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.115, green: 0.12, blue: 0.15),
                                              Color(red: 0.012, green: 0.014, blue: 0.025)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: tile * 0.2237, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.24),
                                                              FlowColor.indigoBright.opacity(0.16)],
                                                     startPoint: .top, endPoint: .bottom),
                                      lineWidth: size * 0.004)
                )
                .frame(width: tile, height: tile)
                .shadow(color: .black.opacity(0.40), radius: size * 0.025, y: size * 0.010)

            // High-contrast medallion keeps the mascot recognizable in the Dock
            // and Finder at 16–32 pt, while the onyx tile preserves the brand.
            Circle()
                .fill(LinearGradient(colors: [Color.white,
                                              Color(red: 0.91, green: 0.91, blue: 0.94)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().strokeBorder(.white.opacity(0.70), lineWidth: size * 0.003))
                .frame(width: medallion, height: medallion)
                .shadow(color: .black.opacity(0.32), radius: size * 0.018, y: size * 0.010)

            // Full-body cat silhouette: rounded head, compact body and curled
            // tail, matching the reference's strong black-and-white read.
            AppIconCatGlyph(glyph: glyph)
                .frame(width: glyph, height: glyph)
                .offset(y: tile * 0.018)
        }
        .frame(width: size, height: size)
    }
}

/// Faceted onyx cat mascot — a front-facing cat head built from straight facet
/// edges (black onyx cat figurines are a classic object; this is ours).
/// Symmetric, normalised points.
enum CatGeo {
    // Left side (mirror for right: x -> 1 - x).
    static let earTipL    = (0.21, 0.08)
    static let earOutL    = (0.13, 0.34)
    static let earInL     = (0.40, 0.24)
    static let crown      = (0.50, 0.20)
    static let cheekL     = (0.12, 0.56)
    static let jawL       = (0.30, 0.76)
    static let chinL      = (0.41, 0.825)
    static let chin       = (0.50, 0.84)   // kept for facet lines
    static let eyeL       = (0.34, 0.50)
    static let nose       = (0.50, 0.63)
    static func p(_ q: (Double, Double), _ r: CGRect) -> CGPoint {
        CGPoint(x: r.minX + r.width * q.0, y: r.minY + r.height * q.1)
    }
    static func m(_ q: (Double, Double)) -> (Double, Double) { (1 - q.0, q.1) }
}

struct CatSilhouette: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        path.move(to: CatGeo.p(CatGeo.earTipL, r))
        [CatGeo.earInL, CatGeo.crown, CatGeo.m(CatGeo.earInL), CatGeo.m(CatGeo.earTipL),
         CatGeo.m(CatGeo.earOutL), CatGeo.m(CatGeo.cheekL), CatGeo.m(CatGeo.jawL),
         CatGeo.m(CatGeo.chinL), CatGeo.chinL, CatGeo.jawL, CatGeo.cheekL, CatGeo.earOutL]
            .forEach { path.addLine(to: CatGeo.p($0, r)) }
        path.closeSubpath()
        return path
    }
}

/// Inner-ear triangles — the mascot's lit facets.
struct CatEars: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        for pts in [[CatGeo.earTipL, CatGeo.earInL, CatGeo.earOutL],
                    [CatGeo.m(CatGeo.earTipL), CatGeo.m(CatGeo.earInL), CatGeo.m(CatGeo.earOutL)]] {
            path.move(to: CatGeo.p(pts[0], r))
            path.addLine(to: CatGeo.p(pts[1], r))
            path.addLine(to: CatGeo.p(pts[2], r))
            path.closeSubpath()
        }
        return path
    }
}

/// Interior cut lines: brows, cheekbones, muzzle wedge.
struct CatFacets: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        func line(_ a: (Double, Double), _ b: (Double, Double)) {
            path.move(to: CatGeo.p(a, r)); path.addLine(to: CatGeo.p(b, r))
        }
        line(CatGeo.cheekL, CatGeo.nose)                       // left cheekbone
        line(CatGeo.m(CatGeo.cheekL), CatGeo.nose)             // right cheekbone
        line(CatGeo.nose, CatGeo.chin)                         // muzzle drop
        // Whisker ticks — three short strokes per side.
        line((0.16, 0.62), (0.30, 0.645))
        line((0.17, 0.68), (0.31, 0.69))
        line((0.20, 0.74), (0.325, 0.725))
        line((0.84, 0.62), (0.70, 0.645))
        line((0.83, 0.68), (0.69, 0.69))
        line((0.80, 0.74), (0.675, 0.725))
        return path
    }
}

/// The Onyx Cat drawn at a given glyph size. `blink` scales the eyes shut
/// (1 = open, 0 = closed); shared by the app icon (held open) and the live
/// sidebar mark.
struct OnyxCatGlyph: View {
    var glyph: CGFloat
    var blink: Double = 1

    var body: some View {
        ZStack {
            CatSilhouette()
                .fill(LinearGradient(colors: [Color(red: 0.15, green: 0.15, blue: 0.25),
                                              Color(red: 0.03, green: 0.03, blue: 0.06)],
                                     startPoint: .top, endPoint: .bottom))
            CatEars()
                .fill(LinearGradient(colors: [FlowColor.indigo.opacity(0.70),
                                              FlowColor.indigoDeep.opacity(0.30)],
                                     startPoint: .top, endPoint: .bottom))
            CatFacets()
                .stroke(FlowColor.indigoBright.opacity(0.30),
                        style: StrokeStyle(lineWidth: glyph * 0.011, lineCap: .butt))
                .clipShape(CatSilhouette())
            CatSilhouette()
                .stroke(FlowColor.indigoBright.opacity(0.9),
                        style: StrokeStyle(lineWidth: glyph * 0.016, lineJoin: .round))
            // Glowing almond eyes with slit pupils — the mascot's signature.
            ForEach(0..<2, id: \.self) { i in
                let e = i == 0 ? CatGeo.eyeL : CatGeo.m(CatGeo.eyeL)
                let center = CatGeo.p(e, CGRect(x: 0, y: 0, width: glyph, height: glyph))
                ZStack {
                    Ellipse()
                        .fill(FlowColor.indigoBright)
                        .frame(width: glyph * 0.17, height: max(0.5, glyph * 0.075 * blink))
                    Capsule()
                        .fill(Color(red: 0.05, green: 0.05, blue: 0.12))
                        .frame(width: glyph * 0.022, height: max(0.5, glyph * 0.062 * blink))
                }
                .rotationEffect(.degrees(i == 0 ? 10 : -10))
                .position(center)
                .shadow(color: FlowColor.indigoBright.opacity(0.9 * blink),
                        radius: glyph * 0.03)
            }
            // Tiny nose diamond where the cheekbones meet.
            Facet(pts: [(0.50, 0.60), (0.535, 0.63), (0.50, 0.67), (0.465, 0.63)])
                .fill(FlowColor.indigoBright.opacity(0.75))
                .frame(width: glyph, height: glyph)
        }
        .frame(width: glyph, height: glyph)
    }
}

/// Icon-specific, full-body silhouette. The in-app Onyx Cat stays expressive;
/// the Dock icon stays solid and unmistakable even at 16 pt.
private struct AppIconCatGlyph: View {
    var glyph: CGFloat

    var body: some View {
        ZStack {
            AppIconCatTail()
                .stroke(Color(red: 0.005, green: 0.006, blue: 0.010),
                        style: StrokeStyle(lineWidth: glyph * 0.095,
                                           lineCap: .round, lineJoin: .round))
            AppIconCatBody()
                .fill(Color(red: 0.005, green: 0.006, blue: 0.010))
            AppIconCatHead()
                .fill(Color(red: 0.005, green: 0.006, blue: 0.010))
        }
        .frame(width: glyph, height: glyph)
    }
}

/// Two restrained stacks at the edge of the white field suggest a library
/// without competing with the cat silhouette at small icon sizes.
private struct AppIconLibraryBooks: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        path.addRect(CGRect(x: r.minX + r.width * 0.025, y: r.minY + r.height * 0.48,
                            width: r.width * 0.095, height: r.height * 0.35))
        path.addRect(CGRect(x: r.minX + r.width * 0.13, y: r.minY + r.height * 0.57,
                            width: r.width * 0.075, height: r.height * 0.26))
        path.addRect(CGRect(x: r.minX + r.width * 0.80, y: r.minY + r.height * 0.55,
                            width: r.width * 0.075, height: r.height * 0.28))
        path.addRect(CGRect(x: r.minX + r.width * 0.885, y: r.minY + r.height * 0.45,
                            width: r.width * 0.09, height: r.height * 0.38))
        path.addRect(CGRect(x: r.minX + r.width * 0.015, y: r.minY + r.height * 0.83,
                            width: r.width * 0.97, height: r.height * 0.025))
        return path
    }
}

private struct AppIconCatReadingEyes: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: r.minX + r.width * 0.26,
                                   y: r.minY + r.height * 0.32,
                                   width: r.width * 0.19,
                                   height: r.height * 0.12))
        path.addEllipse(in: CGRect(x: r.minX + r.width * 0.55,
                                   y: r.minY + r.height * 0.32,
                                   width: r.width * 0.19,
                                   height: r.height * 0.12))
        return path
    }
}

private struct AppIconCatReadingPupils: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: r.minX + r.width * 0.345,
                                   y: r.minY + r.height * 0.365,
                                   width: r.width * 0.035,
                                   height: r.height * 0.060))
        path.addEllipse(in: CGRect(x: r.minX + r.width * 0.635,
                                   y: r.minY + r.height * 0.365,
                                   width: r.width * 0.035,
                                   height: r.height * 0.060))
        return path
    }
}

private struct AppIconCatReadingGlasses: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: r.minX + r.width * 0.22,
                                   y: r.minY + r.height * 0.275,
                                   width: r.width * 0.27,
                                   height: r.height * 0.22))
        path.addEllipse(in: CGRect(x: r.minX + r.width * 0.51,
                                   y: r.minY + r.height * 0.275,
                                   width: r.width * 0.27,
                                   height: r.height * 0.22))
        path.move(to: CGPoint(x: r.minX + r.width * 0.49,
                              y: r.minY + r.height * 0.37))
        path.addCurve(
            to: CGPoint(x: r.minX + r.width * 0.51,
                        y: r.minY + r.height * 0.37),
            control1: CGPoint(x: r.minX + r.width * 0.495,
                              y: r.minY + r.height * 0.355),
            control2: CGPoint(x: r.minX + r.width * 0.505,
                              y: r.minY + r.height * 0.355)
        )
        path.move(to: CGPoint(x: r.minX + r.width * 0.22,
                              y: r.minY + r.height * 0.35))
        path.addLine(to: CGPoint(x: r.minX + r.width * 0.14,
                                 y: r.minY + r.height * 0.32))
        path.move(to: CGPoint(x: r.minX + r.width * 0.78,
                              y: r.minY + r.height * 0.35))
        path.addLine(to: CGPoint(x: r.minX + r.width * 0.86,
                                 y: r.minY + r.height * 0.32))
        return path
    }
}

private struct AppIconOpenBookCover: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        var path = Path()
        path.move(to: p(0.16, 0.57))
        path.addLine(to: p(0.49, 0.64))
        path.addLine(to: p(0.51, 0.64))
        path.addLine(to: p(0.84, 0.57))
        path.addLine(to: p(0.79, 0.86))
        path.addLine(to: p(0.51, 0.91))
        path.addLine(to: p(0.49, 0.91))
        path.addLine(to: p(0.21, 0.86))
        path.closeSubpath()
        return path
    }
}

private struct AppIconOpenBookPages: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        var path = Path()
        path.move(to: p(0.19, 0.55))
        path.addCurve(to: p(0.49, 0.62), control1: p(0.30, 0.54), control2: p(0.41, 0.57))
        path.addLine(to: p(0.49, 0.86))
        path.addCurve(to: p(0.23, 0.80), control1: p(0.40, 0.81), control2: p(0.31, 0.79))
        path.closeSubpath()
        path.move(to: p(0.81, 0.55))
        path.addCurve(to: p(0.51, 0.62), control1: p(0.70, 0.54), control2: p(0.59, 0.57))
        path.addLine(to: p(0.51, 0.86))
        path.addCurve(to: p(0.77, 0.80), control1: p(0.60, 0.81), control2: p(0.69, 0.79))
        path.closeSubpath()
        return path
    }
}

private struct AppIconOpenBookDetails: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        var path = Path()
        path.move(to: p(0.50, 0.63))
        path.addLine(to: p(0.50, 0.86))
        for y in [0.66, 0.71, 0.76] as [CGFloat] {
            path.move(to: p(0.27, y))
            path.addLine(to: p(0.43, y + 0.02))
            path.move(to: p(0.73, y))
            path.addLine(to: p(0.57, y + 0.02))
        }
        return path
    }
}

private struct AppIconCatHead: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        var path = Path()
        path.move(to: p(0.23, 0.18))
        path.addCurve(to: p(0.12, 0.08), control1: p(0.18, 0.13), control2: p(0.15, 0.09))
        path.addCurve(to: p(0.12, 0.34), control1: p(0.09, 0.16), control2: p(0.09, 0.27))
        path.addCurve(to: p(0.07, 0.56), control1: p(0.06, 0.40), control2: p(0.04, 0.49))
        path.addCurve(to: p(0.50, 0.70), control1: p(0.11, 0.66), control2: p(0.24, 0.70))
        path.addCurve(to: p(0.93, 0.56), control1: p(0.76, 0.70), control2: p(0.89, 0.66))
        path.addCurve(to: p(0.88, 0.34), control1: p(0.96, 0.49), control2: p(0.94, 0.40))
        path.addCurve(to: p(0.88, 0.08), control1: p(0.91, 0.27), control2: p(0.91, 0.16))
        path.addCurve(to: p(0.77, 0.18), control1: p(0.85, 0.09), control2: p(0.82, 0.13))
        path.addCurve(to: p(0.23, 0.18), control1: p(0.61, 0.13), control2: p(0.39, 0.13))
        path.closeSubpath()
        return path
    }
}

/// Minimal thinking face: both eyes glance upward while one eyebrow rises.
private struct AppIconCatThinkingBrows: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        var path = Path()
        path.move(to: p(0.25, 0.30))
        path.addCurve(to: p(0.43, 0.30), control1: p(0.31, 0.28), control2: p(0.37, 0.28))
        path.move(to: p(0.58, 0.25))
        path.addLine(to: p(0.75, 0.20))
        return path
    }
}

private struct AppIconCatThinkingEyes: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        var path = Path()
        path.move(to: p(0.23, 0.39))
        path.addCurve(to: p(0.47, 0.37), control1: p(0.30, 0.33), control2: p(0.40, 0.32))
        path.addCurve(to: p(0.23, 0.39), control1: p(0.40, 0.44), control2: p(0.30, 0.45))
        path.closeSubpath()
        path.move(to: p(0.53, 0.36))
        path.addCurve(to: p(0.77, 0.33), control1: p(0.60, 0.29), control2: p(0.70, 0.28))
        path.addCurve(to: p(0.53, 0.36), control1: p(0.70, 0.40), control2: p(0.60, 0.41))
        path.closeSubpath()
        return path
    }
}

private struct AppIconCatThinkingPupils: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: r.minX + r.width * 0.365,
                                   y: r.minY + r.height * 0.335,
                                   width: r.width * 0.040,
                                   height: r.height * 0.072))
        path.addEllipse(in: CGRect(x: r.minX + r.width * 0.675,
                                   y: r.minY + r.height * 0.295,
                                   width: r.width * 0.040,
                                   height: r.height * 0.072))
        return path
    }
}

private struct AppIconCatThinkingMouth: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: r.minX + r.width * 0.43,
                              y: r.minY + r.height * 0.555))
        path.addCurve(
            to: CGPoint(x: r.minX + r.width * 0.55,
                        y: r.minY + r.height * 0.555),
            control1: CGPoint(x: r.minX + r.width * 0.47,
                              y: r.minY + r.height * 0.53),
            control2: CGPoint(x: r.minX + r.width * 0.51,
                              y: r.minY + r.height * 0.58)
        )
        return path
    }
}

private struct AppIconCatThinkingPaw: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        var path = Path()
        path.move(to: p(0.58, 0.69))
        path.addCurve(to: p(0.61, 0.56), control1: p(0.57, 0.64), control2: p(0.58, 0.58))
        path.addCurve(to: p(0.69, 0.58), control1: p(0.65, 0.54), control2: p(0.68, 0.55))
        path.addCurve(to: p(0.66, 0.66), control1: p(0.71, 0.61), control2: p(0.70, 0.65))
        path.addLine(to: p(0.67, 0.74))
        path.addCurve(to: p(0.60, 0.74), control1: p(0.65, 0.75), control2: p(0.62, 0.75))
        path.closeSubpath()
        return path
    }
}

private struct AppIconCatThinkingPawCreases: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        for x in [0.625, 0.660] as [CGFloat] {
            path.move(to: CGPoint(x: r.minX + r.width * x,
                                  y: r.minY + r.height * 0.575))
            path.addLine(to: CGPoint(x: r.minX + r.width * (x - 0.008),
                                     y: r.minY + r.height * 0.605))
        }
        return path
    }
}

private struct AppIconCatHelmet: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        var path = Path()
        path.move(to: p(0.22, 0.30))
        path.addLine(to: p(0.25, 0.22))
        path.addCurve(to: p(0.50, 0.10), control1: p(0.30, 0.14), control2: p(0.39, 0.10))
        path.addCurve(to: p(0.75, 0.22), control1: p(0.61, 0.10), control2: p(0.70, 0.14))
        path.addLine(to: p(0.78, 0.30))
        path.addLine(to: p(0.72, 0.35))
        path.addCurve(to: p(0.28, 0.35), control1: p(0.60, 0.31), control2: p(0.40, 0.31))
        path.closeSubpath()
        return path
    }
}

private struct AppIconCatHelmetMount: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        var path = Path()
        path.move(to: p(0.46, 0.16))
        path.addLine(to: p(0.54, 0.16))
        path.addLine(to: p(0.56, 0.23))
        path.addLine(to: p(0.53, 0.29))
        path.addLine(to: p(0.47, 0.29))
        path.addLine(to: p(0.44, 0.23))
        path.closeSubpath()
        return path
    }
}

private struct AppIconCatHelmetRails: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        var path = Path()
        path.move(to: p(0.24, 0.25))
        path.addLine(to: p(0.37, 0.23))
        path.addLine(to: p(0.38, 0.31))
        path.addLine(to: p(0.28, 0.34))
        path.closeSubpath()
        path.move(to: p(0.76, 0.25))
        path.addLine(to: p(0.63, 0.23))
        path.addLine(to: p(0.62, 0.31))
        path.addLine(to: p(0.72, 0.34))
        path.closeSubpath()
        return path
    }
}

private struct AppIconCatGoggles: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        var path = Path()
        path.move(to: p(0.20, 0.36))
        path.addLine(to: p(0.80, 0.36))
        path.addLine(to: p(0.73, 0.44))
        path.addCurve(to: p(0.27, 0.44), control1: p(0.61, 0.49), control2: p(0.39, 0.49))
        path.closeSubpath()
        return path
    }
}

private struct AppIconCatGoggleFrame: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        var path = Path()
        path.move(to: p(0.20, 0.36))
        path.addLine(to: p(0.80, 0.36))
        path.addLine(to: p(0.73, 0.44))
        path.addCurve(to: p(0.27, 0.44), control1: p(0.61, 0.49), control2: p(0.39, 0.49))
        path.closeSubpath()
        return path
    }
}

private struct AppIconCatMask: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        var path = Path()
        path.move(to: p(0.30, 0.51))
        path.addLine(to: p(0.70, 0.51))
        path.addLine(to: p(0.64, 0.66))
        path.addCurve(to: p(0.36, 0.66), control1: p(0.56, 0.71), control2: p(0.44, 0.71))
        path.closeSubpath()
        return path
    }
}

private struct AppIconCatMaskVents: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        for x in [0.40, 0.48, 0.56] as [CGFloat] {
            path.move(to: CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * 0.56))
            path.addLine(to: CGPoint(x: r.minX + r.width * (x + 0.025), y: r.minY + r.height * 0.55))
            path.addLine(to: CGPoint(x: r.minX + r.width * (x + 0.045), y: r.minY + r.height * 0.63))
            path.addLine(to: CGPoint(x: r.minX + r.width * (x + 0.020), y: r.minY + r.height * 0.64))
            path.closeSubpath()
        }
        return path
    }
}

/// An uneven pair of green side-eyes: one is comically wide while the other
/// squints suspiciously. Both pupils look left to sell the jealous glance.
private struct AppIconCatJealousBrows: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        var path = Path()
        path.move(to: p(0.20, 0.28))
        path.addCurve(to: p(0.47, 0.31), control1: p(0.29, 0.22), control2: p(0.40, 0.24))
        path.move(to: p(0.56, 0.31))
        path.addLine(to: p(0.80, 0.26))
        return path
    }
}

private struct AppIconCatJealousEyes: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        var path = Path()
        path.move(to: p(0.19, 0.39))
        path.addCurve(to: p(0.48, 0.39), control1: p(0.27, 0.29), control2: p(0.41, 0.29))
        path.addCurve(to: p(0.19, 0.39), control1: p(0.41, 0.50), control2: p(0.27, 0.52))
        path.closeSubpath()
        path.move(to: p(0.54, 0.39))
        path.addCurve(to: p(0.82, 0.36), control1: p(0.63, 0.34), control2: p(0.75, 0.32))
        path.addCurve(to: p(0.54, 0.39), control1: p(0.73, 0.44), control2: p(0.62, 0.45))
        path.closeSubpath()
        return path
    }
}

private struct AppIconCatJealousPupils: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: r.minX + r.width * 0.235,
                                   y: r.minY + r.height * 0.335,
                                   width: r.width * 0.078, height: r.height * 0.115))
        path.addEllipse(in: CGRect(x: r.minX + r.width * 0.585,
                                   y: r.minY + r.height * 0.355,
                                   width: r.width * 0.042, height: r.height * 0.066))
        return path
    }
}

private struct AppIconCatJealousMouth: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        var path = Path()
        path.move(to: p(0.31, 0.54))
        path.addCurve(to: p(0.72, 0.55), control1: p(0.43, 0.49), control2: p(0.60, 0.50))
        path.addCurve(to: p(0.63, 0.67), control1: p(0.70, 0.60), control2: p(0.67, 0.65))
        path.addCurve(to: p(0.38, 0.64), control1: p(0.55, 0.70), control2: p(0.44, 0.68))
        path.closeSubpath()
        return path
    }
}

private struct AppIconCatJealousTeeth: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        path.addRect(CGRect(x: r.minX + r.width * 0.405, y: r.minY + r.height * 0.535,
                            width: r.width * 0.014, height: r.height * 0.12))
        path.addRect(CGRect(x: r.minX + r.width * 0.505, y: r.minY + r.height * 0.525,
                            width: r.width * 0.014, height: r.height * 0.145))
        path.addRect(CGRect(x: r.minX + r.width * 0.605, y: r.minY + r.height * 0.53,
                            width: r.width * 0.014, height: r.height * 0.125))
        return path
    }
}

private struct AppIconCatGoofyTongue: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: r.minX + r.width * 0.54,
                                   y: r.minY + r.height * 0.59,
                                   width: r.width * 0.15,
                                   height: r.height * 0.17))
        return path
    }
}

private struct AppIconCatGoofyTongueCrease: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: r.minX + r.width * 0.615,
                              y: r.minY + r.height * 0.675))
        path.addLine(to: CGPoint(x: r.minX + r.width * 0.615,
                                 y: r.minY + r.height * 0.735))
        return path
    }
}

private struct AppIconCatComms: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: r.minX + r.width * 0.76, y: r.minY + r.height * 0.40))
        path.addCurve(
            to: CGPoint(x: r.minX + r.width * 0.69, y: r.minY + r.height * 0.59),
            control1: CGPoint(x: r.minX + r.width * 0.84, y: r.minY + r.height * 0.45),
            control2: CGPoint(x: r.minX + r.width * 0.80, y: r.minY + r.height * 0.58)
        )
        return path
    }
}

private struct AppIconCatCommsMic: Shape {
    func path(in r: CGRect) -> Path {
        Path(ellipseIn: CGRect(x: r.minX + r.width * 0.66, y: r.minY + r.height * 0.56,
                               width: r.width * 0.065, height: r.height * 0.055))
    }
}

private struct AppIconCatBody: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        var path = Path()
        path.move(to: p(0.33, 0.60))
        path.addCurve(to: p(0.29, 0.95), control1: p(0.27, 0.70), control2: p(0.27, 0.84))
        path.addCurve(to: p(0.48, 0.98), control1: p(0.35, 0.99), control2: p(0.42, 1.00))
        path.addLine(to: p(0.48, 0.73))
        path.addCurve(to: p(0.52, 0.73), control1: p(0.49, 0.72), control2: p(0.51, 0.72))
        path.addLine(to: p(0.52, 0.98))
        path.addCurve(to: p(0.71, 0.95), control1: p(0.58, 1.00), control2: p(0.65, 0.99))
        path.addCurve(to: p(0.67, 0.60), control1: p(0.73, 0.84), control2: p(0.73, 0.70))
        path.closeSubpath()
        return path
    }
}

private struct AppIconCatTail: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: r.minX + r.width * 0.34, y: r.minY + r.height * 0.72))
        path.addCurve(
            to: CGPoint(x: r.minX + r.width * 0.10, y: r.minY + r.height * 0.80),
            control1: CGPoint(x: r.minX + r.width * 0.26, y: r.minY + r.height * 0.87),
            control2: CGPoint(x: r.minX + r.width * 0.14, y: r.minY + r.height * 0.88)
        )
        path.addCurve(
            to: CGPoint(x: r.minX + r.width * 0.11, y: r.minY + r.height * 0.42),
            control1: CGPoint(x: r.minX + r.width * 0.04, y: r.minY + r.height * 0.72),
            control2: CGPoint(x: r.minX + r.width * 0.18, y: r.minY + r.height * 0.57)
        )
        return path
    }
}

/// Monochrome template rendering of the cat for the menu bar: the silhouette
/// with punched-out eyes, so it adapts to menu-bar appearance like any system
/// icon but is unmistakably ours.
enum OnyxCatStatusIcon {
    static func image(pointSize: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: pointSize, height: pointSize),
                          flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            var path = CatSilhouette().path(in: rect)
            // Punch the eyes out of the silhouette (even-odd fill).
            let g = rect.width
            for e in [CatGeo.eyeL, CatGeo.m(CatGeo.eyeL)] {
                let c = CatGeo.p(e, rect)
                path.addEllipse(in: CGRect(x: c.x - g * 0.10, y: c.y - g * 0.045,
                                           width: g * 0.20, height: g * 0.09))
            }
            ctx.addPath(path.cgPath)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath(using: .evenOdd)
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// The in-app brandmark: the Onyx Cat, alive — it blinks every few seconds and
/// its glow breathes. Matches the app icon exactly (same glyph). Still under
/// Reduce Motion.
struct OnyxCatMark: View {
    var size: CGFloat = 42
    var animated: Bool = true
    @ObservedObject private var motion = MotionPreferences.shared
    @ObservedObject private var gate = AmbientGate.shared
    @ObservedObject private var pulse = CatPulse.shared

    var body: some View {
        Group {
            if animated && !motion.reduceMotion && gate.active {
                // 12fps is plenty: the blink still gets ~3 frames, and the
                // breath/glow move too slowly to show stepping.
                TimelineView(.animation(minimumInterval: 1.0 / 12)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    cat(blink: min(blinkFactor(t), landedBlink(t)),
                        breath: 0.5 + 0.5 * sin(t * 0.9))
                }
            } else {
                cat(blink: 1, breath: 0.6)
            }
        }
        .frame(width: size, height: size)
    }

    /// Eyes snap shut and reopen in the first ~0.26s of each 4.7s cycle.
    private func blinkFactor(_ t: Double) -> Double {
        let phase = (t / 4.7).truncatingRemainder(dividingBy: 1.0)
        guard phase < 0.055 else { return 1 }
        return max(0.08, abs(cos(.pi * phase / 0.055)))
    }

    /// A quick double blink right after a dictation lands — the cat noticed.
    private func landedBlink(_ t: Double) -> Double {
        let since = t - pulse.landedAt
        guard since >= 0, since < 0.62 else { return 1 }
        let phase = since < 0.26 ? since / 0.26 : (since > 0.36 ? (since - 0.36) / 0.26 : -1)
        guard phase >= 0 else { return 1 }
        return max(0.08, abs(cos(.pi * phase)))
    }

    private func cat(blink: Double, breath: Double) -> some View {
        OnyxCatGlyph(glyph: size, blink: blink)
            .compositingGroup()
            .shadow(color: FlowColor.indigo.opacity(0.40 + 0.25 * breath),
                    radius: size * (0.10 + 0.05 * breath))
    }
}

/// The moment a dictation last landed, so the visible mascot can react.
/// One published timestamp: a landing costs a single re-render, and the blink
/// itself rides the mascot's existing (visibility-gated) timeline.
final class CatPulse: ObservableObject {
    static let shared = CatPulse()
    @Published private(set) var landedAt: TimeInterval = 0
    private init() {}

    func landed() {
        landedAt = Date().timeIntervalSinceReferenceDate
    }
}

// MARK: Sound

/// The app's audio voice: quiet, tactile system sounds at low volume — feedback
/// you can feel without looking, never a jingle. Success is, of course, a purr.
/// Gated by Settings.soundFeedback.
enum FlowSound {
    private static func play(_ name: String, volume: Float) {
        guard Settings.soundFeedback else { return }
        guard let sound = NSSound(named: name) else { return }
        sound.volume = volume
        sound.play()
    }
    static func recordStart() { play("Pop", volume: 0.28) }
    static func recordStop()  { play("Tink", volume: 0.14) }
    static func success()     { play("Purr", volume: 0.35) }
    static func error()       { play("Basso", volume: 0.25) }
}

// MARK: Type

enum FlowType {
    private static func tag(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { ($0 << 8) | Int($1.value & 0xFF) }
    }

    /// Fraunces — the bundled variable display serif — with explicit axis control.
    ///
    /// The font ships with the *text* optical size as default; `opsz` is pushed
    /// high here so headings get Fraunces' dramatic high-contrast *display* cut.
    /// `SOFT` rounds the terminals for a friendlier voice; `WONK` adds the
    /// characterful swashes. Falls back to the system serif if the bundled font
    /// failed to register, so the app never renders a broken glyph box.
    static func fraunces(_ size: CGFloat, weight: CGFloat = 400, opsz: CGFloat = 144,
                         soft: CGFloat = 0, wonk: CGFloat = 0) -> Font {
        let variations: [Int: CGFloat] = [
            tag("opsz"): opsz, tag("wght"): weight, tag("SOFT"): soft, tag("WONK"): wonk,
        ]
        let desc = NSFontDescriptor(fontAttributes: [
            .family: "Fraunces",
            NSFontDescriptor.AttributeName(kCTFontVariationAttribute as String): variations,
        ])
        if let ns = NSFont(descriptor: desc, size: size) {
            return Font(ns)
        }
        return .system(size: size, weight: .medium, design: .serif)
    }

    /// Editorial hero heading (Insights "Welcome back", onboarding titles).
    static var hero: Font   { fraunces(44, weight: 360, opsz: 144, soft: 40) }
    /// Section display heading, one step down from the hero.
    static var title: Font  { fraunces(26, weight: 420, opsz: 96,  soft: 30) }
}

// MARK: Motion
//
// Cinematic & smooth: slow exponential ease-out settles, no bounce/overshoot.
// Reveals are scoped to editorial surfaces (Insights, onboarding) the user opens
// to reflect on — never the pill or dense task panels. Always applied through
// `MotionPreferences.anim(_:)` so Reduce Motion collapses them to an instant cut.

enum FlowMotion {
    /// Cinematic ease-out for content settles and section reveals.
    static let smooth   = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.55)
    /// Longer, more deliberate curve for the hero entrance.
    static let entrance = Animation.timingCurve(0.16, 1.0, 0.30, 1.0, duration: 0.72)
    /// Quick feedback (hover, press) — stays inside the product 150–250 ms band.
    static let quick    = Animation.easeOut(duration: 0.18)

    /// The entrance curve, delayed by `index` steps, for staggered section reveals.
    static func stagger(_ index: Int, step: Double = 0.07) -> Animation {
        entrance.delay(Double(index) * step)
    }
}
