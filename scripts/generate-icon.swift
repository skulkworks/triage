#!/usr/bin/env swift
//
// generate-icon.swift — draws Triage's macOS app icon, and writes every form of it:
//
//   swift scripts/generate-icon.swift            → Triage/Resources/Assets.xcassets/AppIcon.appiconset
//                                                  (macOS 14 / 15: tile and shadows baked in,
//                                                   every size from 16 to 1024)
//   swift scripts/generate-icon.swift --layers   → Triage/AppIcon.icon/Assets/*.png
//                                                  (macOS 26: full-bleed layers with no tile of
//                                                   their own, so Icon Composer's tile, shadow
//                                                   and material do that work)
//   swift scripts/generate-icon.swift --svg      → ../skulkworks-design/app-icons/icon-triage.svg
//                                                  (the canonical design source)
//
// When both AppIcon.icon and AppIcon.appiconset are present, actool uses the .icon and
// generates the older systems' renditions from it — the appiconset is the fallback for a
// build without the layered bundle, not a second thing to keep in step by hand. One source
// for all three, so they can never drift apart.
//
// Design: an army field-hospital tent, the MASH kind, which is where the word "triage" comes
// from. Seen from the front corner: a sage canvas roof with its front edge rolled over the
// gable, an olive gable wall carrying a cream medical cross, and the door open with a warm
// amber lamp lit inside, spilling a little light onto the ground. Olive and sage for the
// canvas, cream for the cross, amber for the door — taken from Andy's sketch — on the same
// slate tile as Riffle. No text; the roof seams, scalloped eave and pole tip are there for the
// large sizes and nothing depends on them, so at 16px it still reads as "green tent, lit door".
//
// Drawn in SwiftUI rather than Core Graphics for one reason: the tile is Apple's real
// continuous-corner squircle (824×824 on a 1024 canvas, radius 185.4), and a CGPath
// rounded rect is visibly not that curve at this radius.
//
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

func hex(_ value: UInt32, _ opacity: Double = 1) -> Color {
    Color(.sRGB,
          red: Double((value >> 16) & 0xFF) / 255,
          green: Double((value >> 8) & 0xFF) / 255,
          blue: Double(value & 0xFF) / 255,
          opacity: opacity)
}

let canvas: CGFloat = 1024
/// The tile: 824 square, centered, with Apple's continuous corner radius.
let tileSide: CGFloat = 824
let tileRadius: CGFloat = 185.4

enum Palette {
    // The canvas. The roof faces the sky and takes the most light; the gable faces the
    // viewer; the side wall turns away and sits in shade.
    static let roofTop: UInt32 = 0xB3C98E
    static let roofBottom: UInt32 = 0x87A066
    static let pole: UInt32 = 0xC3D4A3
    static let seam: UInt32 = 0x7A9459      // the stitched panel seams across the roof
    static let hem: UInt32 = 0xC3D4A3        // the roof's rolled front edge
    static let hemShade: UInt32 = 0x9BB27A
    static let gableTop: UInt32 = 0x6E864B
    static let gableBottom: UInt32 = 0x586D3C
    static let sideTop: UInt32 = 0x4B5C34
    static let sideBottom: UInt32 = 0x3A4829
    static let flap: UInt32 = 0xA9BF88       // the door's tied-back flaps and the rolled flap
    static let flapShade: UInt32 = 0x88A066
    // The cross and the lamp-lit door.
    static let creamTop: UInt32 = 0xFBF1DA
    static let creamBottom: UInt32 = 0xE9D9B6
    static let lampCore: UInt32 = 0xFFCB5C
    static let lampEdge: UInt32 = 0xF28C1C
    static let spill: UInt32 = 0xFFB548
    static let shadow: UInt32 = 0x05080C
}

// MARK: - Geometry

/// A point on the 1024 canvas.
func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// The tent, worked out once as canvas coordinates so the SwiftUI drawing and the SVG are
/// built from the same numbers.
///
/// The gable faces the viewer as a flat elevation, and the long side recedes to a
/// vanishing point far off to the left at eye level — one-point perspective, which keeps
/// the front calm and square while still showing the roof and side wall.
enum Tent {
    static let vanishing = pt(-900, 612)
    /// How far toward the vanishing point the back of the tent sits.
    static let depth: CGFloat = 0.15

    static func back(_ p: CGPoint) -> CGPoint {
        pt(p.x + depth * (vanishing.x - p.x), p.y + depth * (vanishing.y - p.y))
    }

    // The gable end, symmetric about x = 604. The walls splay a little toward the ground,
    // the way canvas pulled out to its pegs does.
    static let apex = pt(604, 316)
    static let eaveLeft = pt(392, 550)
    static let eaveRight = pt(816, 550)
    static let footLeft = pt(360, 734)
    static let footRight = pt(848, 734)

    // The same corners at the back of the tent.
    static let ridgeBack = back(apex)
    static let eaveBack = back(eaveLeft)
    static let footBack = back(footLeft)

    /// The roof canvas overhangs the walls: out past the eave and past the gable.
    static let overhang = CGSize(width: 18, height: 8)
    static let eaveLeftOut = pt(eaveLeft.x - overhang.width, eaveLeft.y + overhang.height)
    static let eaveRightOut = pt(eaveRight.x + overhang.width, eaveRight.y + overhang.height)
    static let eaveBackOut = pt(eaveBack.x - overhang.width * 0.8, eaveBack.y + overhang.height * 0.8)

    static let ridgeSag: CGFloat = 9
    static let scallop: CGFloat = 10
    static let scallops = 3

    static let ridgeMid = pt((apex.x + ridgeBack.x) / 2, (apex.y + ridgeBack.y) / 2)
    static let eaveMid = pt((eaveLeftOut.x + eaveBackOut.x) / 2, (eaveLeftOut.y + eaveBackOut.y) / 2)

    /// The rolled front edge of the roof, drawn as a thick round-capped stroke.
    static let hemWidth: CGFloat = 32

    // The door: a trapezoid, narrower at the top, right of the gable's center.
    static let doorTop: CGFloat = 584
    static let doorBottom: CGFloat = 734
    static let doorCenter: CGFloat = 712
    static let doorTopHalf: CGFloat = 48
    static let doorBottomHalf: CGFloat = 64

    // The cross, on the gable left of the door.
    static let crossCenter = pt(502, 634)
    static let crossArm: CGFloat = 136       // tip to tip
    static let crossBar: CGFloat = 46        // thickness of each bar
}

/// A polygon with every corner rounded, so the canvas reads as cloth rather than sheet metal.
func roundedPolygon(_ points: [CGPoint], radius: CGFloat) -> Path {
    roundedPolygon(points.map { ($0, radius) })
}

/// The same, with a radius per corner; a radius of 0 leaves that point sharp, which is how
/// a curve sampled into short straight runs passes through without kinks.
func roundedPolygon(_ corners: [(point: CGPoint, radius: CGFloat)]) -> Path {
    var path = Path()
    let first = corners[0].point, last = corners[corners.count - 1].point
    path.move(to: pt((last.x + first.x) / 2, (last.y + first.y) / 2))
    for i in corners.indices {
        let next = corners[(i + 1) % corners.count].point
        if corners[i].radius > 0 {
            path.addArc(tangent1End: corners[i].point, tangent2End: next,
                        radius: corners[i].radius)
        } else {
            path.addLine(to: corners[i].point)
        }
    }
    path.closeSubpath()
    return path
}

/// Points strictly between `a` and `b`, pushed down by `drop(f)` at each fraction `f` —
/// used for the ridge sagging between its poles and the eave hanging between its pegs.
func sampled(_ a: CGPoint, _ b: CGPoint, steps: Int = 24,
             drop: (CGFloat) -> CGFloat) -> [CGPoint] {
    (1..<steps).map { i in
        let f = CGFloat(i) / CGFloat(steps)
        return pt(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f + drop(f))
    }
}

/// The pieces of the tent as paths. Each is used for the SwiftUI drawing and written
/// straight into the SVG, so the two cannot disagree.
enum Pieces {
    static var sideWall: Path {
        roundedPolygon([Tent.eaveLeft, Tent.eaveBack, Tent.footBack, Tent.footLeft], radius: 10)
    }

    /// The gable wall runs up to the apex; the roof hem is drawn over its top edges.
    static var gable: Path {
        roundedPolygon([Tent.footLeft, Tent.eaveLeft, pt(Tent.apex.x, Tent.apex.y + 10),
                        Tent.eaveRight, Tent.footRight], radius: 10)
    }

    /// The top of the tent pole, standing proud of the ridge.
    static var pole: Path {
        Path(roundedRect: CGRect(x: Tent.apex.x - 9, y: Tent.apex.y - 44, width: 18, height: 60),
             cornerRadius: 9, style: .circular)
    }

    static var roof: Path {
        // Canvas between poles sags a little, and the eave hangs in shallow scallops
        // between its tie-downs — the two things that say tent rather than shed.
        // The roof's front corner starts just under the apex, hidden by the rolled edge, so
        // the rounding there can't poke out past it as a sliver.
        let front = pt(Tent.apex.x, Tent.apex.y + 14)
        let ridge = sampled(front, Tent.ridgeBack) { f in Tent.ridgeSag * sin(.pi * f) }
        let eave = sampled(Tent.eaveBackOut, Tent.eaveLeftOut, steps: 36) { f in
            Tent.scallop * sin(.pi * (f * CGFloat(Tent.scallops)).truncatingRemainder(dividingBy: 1))
        }
        var corners: [(point: CGPoint, radius: CGFloat)] = [(front, 0)]
        corners += ridge.map { (point: $0, radius: CGFloat(0)) }
        corners += [(Tent.ridgeBack, 14), (Tent.eaveBackOut, 10)]
        corners += eave.map { (point: $0, radius: CGFloat(0)) }
        corners += [(Tent.eaveLeftOut, 10)]
        return roundedPolygon(corners)
    }

    /// The center line of the rolled front edge, from eave to apex to eave.
    static var hem: Path {
        var path = Path()
        path.move(to: Tent.eaveLeftOut)
        path.addLine(to: Tent.apex)
        path.addLine(to: Tent.eaveRightOut)
        return path
    }

    /// Two seams across the roof, running from ridge to eave like the canvas panels do.
    static var seams: Path {
        func along(_ a: CGPoint, _ b: CGPoint, _ f: CGFloat) -> CGPoint {
            pt(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
        }
        var path = Path()
        for f in [CGFloat(0.36), 0.68] {
            let top = along(Tent.apex, Tent.ridgeBack, f)
            let bottom = along(Tent.eaveLeftOut, Tent.eaveBackOut, f)
            path.move(to: along(top, bottom, 0.10))
            path.addLine(to: along(top, bottom, 0.90))
        }
        return path
    }
    static let seamWidth: CGFloat = 5

    static var door: Path {
        let t = Tent.doorTop, b = Tent.doorBottom, c = Tent.doorCenter
        return roundedPolygon([pt(c - Tent.doorTopHalf, t), pt(c + Tent.doorTopHalf, t),
                               pt(c + Tent.doorBottomHalf, b), pt(c - Tent.doorBottomHalf, b)],
                              radius: 8)
    }

    /// The two door flaps, drawn back to either side: narrow where they leave the roll,
    /// wider where the canvas falls to the ground.
    static var flaps: Path {
        let t = Tent.doorTop, b = Tent.doorBottom, c = Tent.doorCenter
        let topIn = Tent.doorTopHalf - 4, topOut = Tent.doorTopHalf + 14
        let bottomIn = Tent.doorBottomHalf - 6, bottomOut = Tent.doorBottomHalf + 30
        var path = roundedPolygon([pt(c - topOut, t), pt(c - topIn, t),
                                   pt(c - bottomIn, b), pt(c - bottomOut, b)], radius: 6)
        path.addPath(roundedPolygon([pt(c + topIn, t), pt(c + topOut, t),
                                     pt(c + bottomOut, b), pt(c + bottomIn, b)], radius: 6))
        return path
    }

    /// The door flap rolled up over the opening.
    static var roll: Path {
        let w = (Tent.doorTopHalf + 14) * 2 + 26, h: CGFloat = 36
        return Path(roundedRect: CGRect(x: Tent.doorCenter - w / 2, y: Tent.doorTop - h + 8,
                                        width: w, height: h),
                    cornerRadius: h / 2, style: .circular)
    }

    static var cross: Path {
        let c = Tent.crossCenter, a = Tent.crossArm / 2, b = Tent.crossBar / 2
        let r: CGFloat = 7
        var path = Path()
        path.addRoundedRect(in: CGRect(x: c.x - b, y: c.y - a, width: b * 2, height: a * 2),
                            cornerSize: CGSize(width: r, height: r), style: .circular)
        path.addRoundedRect(in: CGRect(x: c.x - a, y: c.y - b, width: a * 2, height: b * 2),
                            cornerSize: CGSize(width: r, height: r), style: .circular)
        return path
    }

    // Soft ellipses on the ground: the tent's shadow, and the lamp light out of the door.
    static let groundShadow = CGRect(x: Tent.footBack.x - 40, y: 690, width: 760, height: 90)
    static let spill = CGRect(x: Tent.doorCenter - 110, y: 718, width: 220, height: 44)
}

// MARK: - The artwork

/// A path drawn as a SwiftUI view on the full canvas.
struct CanvasPath: Shape {
    let path: Path
    func path(in rect: CGRect) -> Path { path }
}

/// A gradient between two canvas points, so it lands where it would in the SVG
/// (`gradientUnits="userSpaceOnUse"`), whatever piece it fills.
func linear(_ from: CGPoint, _ to: CGPoint, _ stops: [(UInt32, Double, CGFloat)]) -> LinearGradient {
    LinearGradient(
        stops: stops.map { .init(color: hex($0.0, $0.1), location: $0.2) },
        startPoint: UnitPoint(x: from.x / canvas, y: from.y / canvas),
        endPoint: UnitPoint(x: to.x / canvas, y: to.y / canvas))
}

enum Gradients {
    /// Lit along the ridge, darker toward the eave.
    static let roof = (from: Tent.ridgeMid, to: Tent.eaveMid,
                       stops: [(Palette.roofTop, 1.0, CGFloat(0)), (Palette.roofBottom, 1.0, 1)])
    /// The lit top edge: light caught along the ridge, gone a quarter of the way down.
    static let ridge = (from: Tent.ridgeMid, to: Tent.eaveMid,
                        stops: [(UInt32(0xFFFFFF), 0.30, CGFloat(0)), (UInt32(0xFFFFFF), 0, 0.26)])
    static let hem = (from: pt(Tent.apex.x, Tent.apex.y - 40), to: pt(Tent.apex.x, Tent.eaveRight.y + 20),
                      stops: [(Palette.hem, 1.0, CGFloat(0)), (Palette.hemShade, 1.0, 1)])
    static let gable = (from: pt(Tent.apex.x, Tent.apex.y + 20), to: pt(Tent.apex.x, Tent.footLeft.y),
                        stops: [(Palette.gableTop, 1.0, CGFloat(0)), (Palette.gableBottom, 1.0, 1)])
    static let side = (from: pt(Tent.eaveBack.x, Tent.eaveLeft.y), to: pt(Tent.eaveBack.x, Tent.footLeft.y),
                       stops: [(Palette.sideTop, 1.0, CGFloat(0)), (Palette.sideBottom, 1.0, 1)])
    static let flap = (from: pt(Tent.doorCenter, Tent.doorTop), to: pt(Tent.doorCenter, Tent.doorBottom),
                       stops: [(Palette.flap, 1.0, CGFloat(0)), (Palette.flapShade, 1.0, 1)])
    static let cross = (from: pt(Tent.crossCenter.x, Tent.crossCenter.y - Tent.crossArm / 2),
                        to: pt(Tent.crossCenter.x, Tent.crossCenter.y + Tent.crossArm / 2),
                        stops: [(Palette.creamTop, 1.0, CGFloat(0)), (Palette.creamBottom, 1.0, 1)])
    /// The lamp sits low in the tent, so the doorway is brightest near the floor.
    static let lamp = (from: pt(Tent.doorCenter, Tent.doorBottom), to: pt(Tent.doorCenter, Tent.doorTop),
                       stops: [(Palette.lampCore, 1.0, CGFloat(0)), (Palette.lampEdge, 1.0, 1)])
}

func fill<G>(_ g: (from: CGPoint, to: CGPoint, stops: G)) -> LinearGradient
where G: Collection, G.Element == (UInt32, Double, CGFloat) {
    linear(g.from, g.to, Array(g.stops))
}

/// Stacked shadows, applied in order.
struct Shadows: ViewModifier {
    let shadows: [(color: Color, radius: CGFloat, y: CGFloat)]

    func body(content: Content) -> some View {
        shadows.reduce(AnyView(content)) { view, shadow in
            AnyView(view.shadow(color: shadow.color, radius: shadow.radius, x: 0, y: shadow.y))
        }
    }
}

/// The pieces the icon is made of, so the baked tile and the layered `.icon` bundle are
/// built from the same drawing rather than from two that look alike today.
enum IconParts {

    /// The tent's own drop shadow: a wide soft one and a tight one at the base.
    static let tentShadow: [(color: Color, radius: CGFloat, y: CGFloat)] =
        [(hex(Palette.shadow, 0.30), 26, 20), (hex(Palette.shadow, 0.18), 5, 4)]
    /// What lifts the door flaps and the cross off the canvas behind them.
    static let detailShadow: [(color: Color, radius: CGFloat, y: CGFloat)] =
        [(hex(Palette.shadow, 0.28), 5, 4)]

    /// The slate body, the same three stops as Riffle so the two sit together in the Dock.
    /// The two end stops are also what `icon.json` declares as its background fill, so the
    /// layered icon starts from the same colour.
    static let bodyTop: UInt32 = 0x3C475C
    static let bodyMid: UInt32 = 0x28303F
    static let bodyBottom: UInt32 = 0x141924

    @ViewBuilder
    static var background: some View {
        ZStack {
            LinearGradient(
                stops: [.init(color: hex(bodyTop), location: 0),
                        .init(color: hex(bodyMid), location: 0.52),
                        .init(color: hex(bodyBottom), location: 1)],
                startPoint: UnitPoint(x: 0.1, y: 0), endPoint: UnitPoint(x: 0.9, y: 1))
            RadialGradient(
                stops: [.init(color: .white.opacity(0.18), location: 0),
                        .init(color: .white.opacity(0.04), location: 0.6),
                        .init(color: .white.opacity(0), location: 1)],
                center: UnitPoint(x: 0.5, y: 0.28), startRadius: 0, endRadius: canvas * 0.78)
            // A rim: lit along the top, weighted along the bottom.
            LinearGradient(
                stops: [.init(color: .white.opacity(0.22), location: 0),
                        .init(color: .white.opacity(0), location: 0.10),
                        .init(color: .black.opacity(0), location: 0.86),
                        .init(color: .black.opacity(0.20), location: 1)],
                startPoint: .top, endPoint: .bottom)
        }
    }

    /// How much larger the tent is drawn for the layered icon.
    ///
    /// The baked tile is 824 on a 1024 canvas, so the artwork is sized against *that*. A
    /// `.icon` layer is placed against the full canvas, because macOS 26 supplies the tile;
    /// drawn at the baked size the tent would sit inside two insets and read small.
    static let layerScale: CGFloat = canvas / tileSide

    /// The tent itself: walls, roof, the open doorway and the light it throws.
    /// `shadowed` is false for the layered icon, which gets its shadows from the system.
    static func tent(shadowed: Bool) -> some View {
        placed(scale: shadowed ? 1 : layerScale) {
            ZStack {
                if shadowed {
                    // The tent standing on the ground, before the light pool goes over it.
                    Ellipse()
                        .fill(EllipticalGradient(
                            stops: [.init(color: hex(Palette.shadow, 0.55), location: 0),
                                    .init(color: hex(Palette.shadow, 0), location: 1)]))
                        .frame(width: Pieces.groundShadow.width, height: Pieces.groundShadow.height)
                        .position(x: Pieces.groundShadow.midX, y: Pieces.groundShadow.midY)
                }
                ZStack {
                    CanvasPath(path: Pieces.pole).fill(hex(Palette.pole))
                    CanvasPath(path: Pieces.sideWall).fill(fill(Gradients.side))
                    CanvasPath(path: Pieces.gable).fill(fill(Gradients.gable))
                    CanvasPath(path: Pieces.door).fill(fill(Gradients.lamp))
                    // The roof and its rolled edge cast a short shadow onto the walls.
                    ZStack {
                        CanvasPath(path: Pieces.roof).fill(fill(Gradients.roof))
                        CanvasPath(path: Pieces.seams)
                            .stroke(hex(Palette.seam, 0.55),
                                    style: StrokeStyle(lineWidth: Pieces.seamWidth, lineCap: .round))
                        CanvasPath(path: Pieces.roof).fill(fill(Gradients.ridge))
                        CanvasPath(path: Pieces.hem)
                            .stroke(fill(Gradients.hem),
                                    style: StrokeStyle(lineWidth: Tent.hemWidth,
                                                       lineCap: .round, lineJoin: .round))
                    }
                    // Flattened first, so the roof casts one shadow rather than every
                    // seam and highlight on it casting its own.
                    .compositingGroup()
                    .shadow(color: hex(Palette.shadow, 0.35), radius: 8, x: 0, y: 7)
                }
                .compositingGroup()
                .modifier(Shadows(shadows: shadowed ? tentShadow : []))
                // Lamp light on the ground in front of the door.
                Ellipse()
                    .fill(EllipticalGradient(
                        stops: [.init(color: hex(Palette.spill, 0.55), location: 0),
                                .init(color: hex(Palette.spill, 0), location: 1)]))
                    .frame(width: Pieces.spill.width, height: Pieces.spill.height)
                    .position(x: Pieces.spill.midX, y: Pieces.spill.midY)
            }
        }
    }

    /// The details carried in front of the canvas: the door's flaps and the cross.
    static func details(shadowed: Bool) -> some View {
        placed(scale: shadowed ? 1 : layerScale) {
            ZStack {
                CanvasPath(path: Pieces.flaps).fill(fill(Gradients.flap))
                CanvasPath(path: Pieces.roll).fill(fill(Gradients.hem))
                CanvasPath(path: Pieces.cross).fill(fill(Gradients.cross))
            }
            .compositingGroup()
            .modifier(Shadows(shadows: shadowed ? detailShadow : []))
        }
    }

    /// The tent is drawn a little large and lifted, because its weight is in the walls at
    /// the bottom and drawn dead center it looks like it is sliding off the tile. Every part
    /// takes the same placement, which is what keeps the layers registered with each other.
    static let placementScale: CGFloat = 1.04
    static let placementLift: CGFloat = -16

    private static func placed<Content: View>(
        scale: CGFloat, @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .frame(width: canvas, height: canvas)
            .scaleEffect(placementScale * scale, anchor: .center)
            .offset(y: placementLift * scale)
    }
}

/// The whole icon on its tile — what macOS 14 and 15 need, since they take a finished
/// picture rather than layers.
struct IconArtwork: View {
    var body: some View {
        ZStack {
            IconParts.background
            IconParts.tent(shadowed: true)
            IconParts.details(shadowed: true)
        }
        .frame(width: canvas, height: canvas)
        // Cropped to the tile rather than drawn inside it: the gradients run edge to edge
        // and the corners take their colour from wherever they land.
        .mask(RoundedRectangle(cornerRadius: tileRadius, style: .continuous)
            .frame(width: tileSide, height: tileSide))
    }
}

/// One layer of the `.icon` bundle: full-bleed, unmasked, unshadowed, transparent
/// everywhere it isn't drawing. macOS 26 supplies the tile, the shadow and the material,
/// and artwork that brought its own would be doing that work twice.
struct IconLayer: View {
    let content: AnyView

    var body: some View {
        content
            .frame(width: canvas, height: canvas)
    }
}

// MARK: - Rendering

@MainActor
func render(_ view: some View) -> CGImage {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    // The layers are mostly transparent, and an opaque renderer would fill that with
    // white — which would hide every layer under the topmost one.
    renderer.isOpaque = false
    guard let image = renderer.cgImage else {
        FileHandle.standardError.write(Data("could not render the icon\n".utf8))
        exit(1)
    }
    return image
}

@MainActor
func renderMaster() -> CGImage { render(IconArtwork()) }

/// Downsamples the 1024 master rather than re-rendering at each size: shadows and
/// hairlines drawn at 16pt are mud, and drawn at 1024 then reduced they survive.
func scaled(_ image: CGImage, to size: Int) -> CGImage {
    guard size != image.width else { return image }
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Could not create destination for \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        fatalError("Could not write \(url.path)")
    }
}

// MARK: - Output

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()

@MainActor
func generate() {
    // scripts/generate-icon.swift → ../Triage/Resources/Assets.xcassets/AppIcon.appiconset
    let iconset = repoRoot.appendingPathComponent(
        "Triage/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
    try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    let master = renderMaster()

    // Unique pixel dimensions → one PNG each (shared across @1x/@2x slots).
    for px in [16, 32, 64, 128, 256, 512, 1024] {
        writePNG(scaled(master, to: px), to: iconset.appendingPathComponent("icon_\(px).png"))
        print("wrote icon_\(px).png")
    }

    // The 10-slot macOS Contents.json mapping @1x/@2x to the shared PNGs.
    struct Slot { let size: Int; let scale: Int; let file: Int }
    let slots = [
        Slot(size: 16, scale: 1, file: 16), Slot(size: 16, scale: 2, file: 32),
        Slot(size: 32, scale: 1, file: 32), Slot(size: 32, scale: 2, file: 64),
        Slot(size: 128, scale: 1, file: 128), Slot(size: 128, scale: 2, file: 256),
        Slot(size: 256, scale: 1, file: 256), Slot(size: 256, scale: 2, file: 512),
        Slot(size: 512, scale: 1, file: 512), Slot(size: 512, scale: 2, file: 1024),
    ]
    let images = slots.map { slot in
        """
            {
              "idiom" : "mac",
              "size" : "\(slot.size)x\(slot.size)",
              "scale" : "\(slot.scale)x",
              "filename" : "icon_\(slot.file).png"
            }
        """
    }
    let contents = """
    {
      "images" : [
    \(images.joined(separator: ",\n"))
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
    try! contents.write(to: iconset.appendingPathComponent("Contents.json"),
                        atomically: true, encoding: .utf8)
    print("wrote Contents.json")
}

/// Writes the `.icon` bundle's layer artwork. `icon.json` beside it names these files and
/// carries the background fill, the shadows and the material — it is checked in and edited
/// by hand (or in Icon Composer), not generated here.
@MainActor
func generateLayers() {
    let assets = repoRoot.appendingPathComponent("Triage/AppIcon.icon/Assets", isDirectory: true)
    try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

    let layers: [(name: String, view: AnyView)] = [
        ("tent", AnyView(IconParts.tent(shadowed: false))),
        ("details", AnyView(IconParts.details(shadowed: false))),
    ]
    for layer in layers {
        writePNG(render(IconLayer(content: layer.view)),
                 to: assets.appendingPathComponent("\(layer.name).png"))
        print("wrote \(layer.name).png")
    }
}

// MARK: - The canonical SVG

/// SVG path data for any SwiftUI path, read from its own Bézier segments — which is also
/// how the continuous-corner tile gets into the SVG, since `rx` is a circular arc and
/// visibly not the curve macOS uses.
func svgPath(_ path: Path) -> String {
    var out: [String] = []
    func fmt(_ value: CGFloat) -> String {
        String(format: "%g", (value * 100).rounded() / 100)
    }
    path.cgPath.applyWithBlock { element in
        let p = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint:
            out.append("M\(fmt(p[0].x)) \(fmt(p[0].y))")
        case .addLineToPoint:
            out.append("L\(fmt(p[0].x)) \(fmt(p[0].y))")
        case .addQuadCurveToPoint:
            out.append("Q\(fmt(p[0].x)) \(fmt(p[0].y)) \(fmt(p[1].x)) \(fmt(p[1].y))")
        case .addCurveToPoint:
            out.append("C\(fmt(p[0].x)) \(fmt(p[0].y)) \(fmt(p[1].x)) \(fmt(p[1].y)) \(fmt(p[2].x)) \(fmt(p[2].y))")
        case .closeSubpath:
            out.append("Z")
        @unknown default:
            break
        }
    }
    return out.joined(separator: " ")
}

func svgHex(_ value: UInt32) -> String { String(format: "#%06X", value) }

/// A number for an SVG attribute: three decimals at most, and no trailing zeroes.
func svgNum(_ value: CGFloat) -> String {
    String(format: "%.3f", value)
        .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
}

/// A `userSpaceOnUse` gradient from the same endpoints and stops the SwiftUI drawing uses.
func svgGradient<G>(_ id: String, _ g: (from: CGPoint, to: CGPoint, stops: G)) -> String
where G: Collection, G.Element == (UInt32, Double, CGFloat) {
    let stops = g.stops.map { stop in
        let opacity = stop.1 < 1 ? " stop-opacity=\"\(svgNum(stop.1))\"" : ""
        return "<stop offset=\"\(svgNum(stop.2))\" stop-color=\"\(svgHex(stop.0))\"\(opacity)/>"
    }.joined()
    return """
        <linearGradient id="\(id)" gradientUnits="userSpaceOnUse" x1="\(svgNum(g.from.x))" y1="\(svgNum(g.from.y))" x2="\(svgNum(g.to.x))" y2="\(svgNum(g.to.y))">\(stops)</linearGradient>
    """
}

func svgEllipse(_ rect: CGRect, fill: String) -> String {
    "<ellipse cx=\"\(svgNum(rect.midX))\" cy=\"\(svgNum(rect.midY))\" rx=\"\(svgNum(rect.width / 2))\" ry=\"\(svgNum(rect.height / 2))\" fill=\"url(#\(fill))\"/>"
}

/// SwiftUI's shadow radius is roughly twice an SVG blur's standard deviation.
func svgShadow(_ shadows: [(color: Color, radius: CGFloat, y: CGFloat)], opacities: [Double]) -> String {
    zip(shadows, opacities).map { shadow, opacity in
        "<feDropShadow dx=\"0\" dy=\"\(svgNum(shadow.y))\" stdDeviation=\"\(svgNum(shadow.radius / 2))\" flood-color=\"\(svgHex(Palette.shadow))\" flood-opacity=\"\(svgNum(opacity))\"/>"
    }.joined(separator: "\n      ")
}

/// Writes the canonical artwork to `skulkworks-design/app-icons/icon-triage.svg`, beside
/// the repo. Generated from the same numbers as the app icon so the design source cannot
/// quietly fall behind what ships.
func generateSVG(to url: URL) throws {
    let tile = RoundedRectangle(cornerRadius: tileRadius, style: .continuous)
        .path(in: CGRect(x: (canvas - tileSide) / 2, y: (canvas - tileSide) / 2,
                         width: tileSide, height: tileSide))

    // The tent's placement, written out once: the same scale about the center and lift
    // the artwork uses.
    let placement = "translate(0 \(svgNum(IconParts.placementLift))) translate(512 512) "
        + "scale(\(svgNum(IconParts.placementScale))) translate(-512 -512)"

    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
      <!-- Triage. Generated by scripts/generate-icon.swift (svg mode) in the triage repo;
           edit there, not here. The tile is Apple's continuous-corner squircle (824 on a
           1024 canvas), written out as Béziers because SVG's rx is a circular arc. -->
      <defs>
        <linearGradient id="body" x1="0.1" y1="0" x2="0.9" y2="1">
          <stop offset="0" stop-color="\(svgHex(IconParts.bodyTop))"/>
          <stop offset="0.52" stop-color="\(svgHex(IconParts.bodyMid))"/>
          <stop offset="1" stop-color="\(svgHex(IconParts.bodyBottom))"/>
        </linearGradient>
        <radialGradient id="glow" cx="0.5" cy="0.28" r="0.78">
          <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.18"/>
          <stop offset="0.6" stop-color="#FFFFFF" stop-opacity="0.04"/>
          <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
        </radialGradient>
        <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.22"/>
          <stop offset="0.1" stop-color="#FFFFFF" stop-opacity="0"/>
          <stop offset="0.86" stop-color="#000000" stop-opacity="0"/>
          <stop offset="1" stop-color="#000000" stop-opacity="0.2"/>
        </linearGradient>
    \(svgGradient("roof", Gradients.roof))
    \(svgGradient("ridge", Gradients.ridge))
    \(svgGradient("hem", Gradients.hem))
    \(svgGradient("gable", Gradients.gable))
    \(svgGradient("side", Gradients.side))
    \(svgGradient("flap", Gradients.flap))
    \(svgGradient("cross", Gradients.cross))
    \(svgGradient("lamp", Gradients.lamp))
        <radialGradient id="ground">
          <stop offset="0" stop-color="\(svgHex(Palette.shadow))" stop-opacity="0.55"/>
          <stop offset="1" stop-color="\(svgHex(Palette.shadow))" stop-opacity="0"/>
        </radialGradient>
        <radialGradient id="spill">
          <stop offset="0" stop-color="\(svgHex(Palette.spill))" stop-opacity="0.55"/>
          <stop offset="1" stop-color="\(svgHex(Palette.spill))" stop-opacity="0"/>
        </radialGradient>
        <filter id="tent" x="-25%" y="-25%" width="150%" height="150%">
          \(svgShadow(IconParts.tentShadow, opacities: [0.30, 0.18]))
        </filter>
        <filter id="roofShadow" x="-25%" y="-25%" width="150%" height="150%">
          <feDropShadow dx="0" dy="7" stdDeviation="4" flood-color="\(svgHex(Palette.shadow))" flood-opacity="0.35"/>
        </filter>
        <filter id="details" x="-25%" y="-25%" width="150%" height="150%">
          \(svgShadow(IconParts.detailShadow, opacities: [0.28]))
        </filter>
        <clipPath id="tile">
          <path d="\(svgPath(tile))"/>
        </clipPath>
      </defs>

      <g clip-path="url(#tile)">
        <rect width="1024" height="1024" fill="url(#body)"/>
        <rect width="1024" height="1024" fill="url(#glow)"/>
        <rect width="1024" height="1024" fill="url(#rim)"/>
        <g transform="\(placement)">
        \(svgEllipse(Pieces.groundShadow, fill: "ground"))
        <g filter="url(#tent)">
          <path d="\(svgPath(Pieces.pole))" fill="\(svgHex(Palette.pole))"/>
          <path d="\(svgPath(Pieces.sideWall))" fill="url(#side)"/>
          <path d="\(svgPath(Pieces.gable))" fill="url(#gable)"/>
          <path d="\(svgPath(Pieces.door))" fill="url(#lamp)"/>
          <g filter="url(#roofShadow)">
            <path d="\(svgPath(Pieces.roof))" fill="url(#roof)"/>
            <path d="\(svgPath(Pieces.seams))" fill="none" stroke="\(svgHex(Palette.seam))" stroke-opacity="0.55" stroke-width="\(svgNum(Pieces.seamWidth))" stroke-linecap="round"/>
            <path d="\(svgPath(Pieces.roof))" fill="url(#ridge)"/>
            <path d="\(svgPath(Pieces.hem))" fill="none" stroke="url(#hem)" stroke-width="\(svgNum(Tent.hemWidth))" stroke-linecap="round" stroke-linejoin="round"/>
          </g>
        </g>
        \(svgEllipse(Pieces.spill, fill: "spill"))
        <g filter="url(#details)">
          <path d="\(svgPath(Pieces.flaps))" fill="url(#flap)"/>
          <path d="\(svgPath(Pieces.roll))" fill="url(#hem)"/>
          <path d="\(svgPath(Pieces.cross))" fill="url(#cross)"/>
        </g>
        </g>
      </g>
    </svg>

    """
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try svg.write(to: url, atomically: true, encoding: .utf8)
    print("wrote \(url.path)")
}

if CommandLine.arguments.contains("--layers") {
    MainActor.assumeIsolated { generateLayers() }
} else if CommandLine.arguments.contains("--svg") {
    // The design repo sits beside this one.
    let svg = repoRoot.deletingLastPathComponent()
        .appendingPathComponent("skulkworks-design/app-icons/icon-triage.svg")
    try generateSVG(to: svg)
} else {
    MainActor.assumeIsolated { generate() }
}
