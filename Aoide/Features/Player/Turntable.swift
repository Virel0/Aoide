import SwiftUI

/// A record on a platter, with the arm down.
///
/// Drawn rather than borrowed: there is no turntable in SF Symbols, and the
/// nearest thing — a compact disc — is the wrong instrument for a feature whose
/// entire vocabulary is bars, pitch faders and bass swaps.
///
/// It spins at 33⅓, because a thing that spins at the wrong speed is a thing
/// somebody notices without being able to say why.
struct Turntable: View {
    var isSpinning = false
    /// Where the arm sits: 0 at the outside edge, 1 at the run-out. A pair of
    /// these with the arms in different places is a mix, at a glance.
    var progress: Double = 0.15
    var tint: Color = .accentColor

    /// One revolution of a twelve-inch at 33⅓ rpm.
    private static let revolution = 1.8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isSpinning)) { context in
            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)
                let angle = isSpinning
                    ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.revolution)
                        / Self.revolution * 360
                    : 0

                ZStack {
                    platter(side: side)
                        .frame(width: side * 0.74, height: side * 0.74)
                        .rotationEffect(.degrees(angle))
                    Tonearm(progress: progress)
                        .frame(width: side, height: side)
                }
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func platter(side: CGFloat) -> some View {
        let disc = side * 0.74
        return ZStack {
            Circle().fill(.black.opacity(0.88))
            // Grooves. Few enough not to moiré at the size this is usually drawn.
            ForEach(1...3, id: \.self) { ring in
                Circle()
                    .strokeBorder(.white.opacity(0.1), lineWidth: max(0.5, disc * 0.012))
                    .padding(disc * 0.09 * CGFloat(ring))
            }
            Circle()
                .fill(tint)
                .frame(width: disc * 0.36, height: disc * 0.36)
            // One mark on the label, because a plain disc rotating looks like a
            // disc standing still.
            Capsule()
                .fill(.black.opacity(0.55))
                .frame(width: max(1, disc * 0.04), height: disc * 0.15)
                .offset(y: -disc * 0.1)
            Circle()
                .fill(.black)
                .frame(width: disc * 0.06, height: disc * 0.06)
        }
    }
}

/// The arm, pivoted outside the record and reaching in.
///
/// Drawn as a path between two computed points rather than as a rotated
/// rectangle: the needle has to land *on* the record, at a radius that shrinks
/// as the side plays, and nesting offsets and rotations to achieve that is how
/// an arm ends up hanging off the corner of the frame.
private struct Tonearm: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let centre = CGPoint(x: side / 2, y: side / 2)
            let pivot = CGPoint(x: side * 0.93, y: side * 0.07)
            // From the outside edge inwards as the record plays.
            let radius = side * 0.37 * (0.94 - 0.62 * min(1, max(0, progress)))
            let dx = pivot.x - centre.x, dy = pivot.y - centre.y
            let length = (dx * dx + dy * dy).squareRoot()
            let needle = CGPoint(x: centre.x + dx / length * radius, y: centre.y + dy / length * radius)
            // A stub the other side of the pivot: the counterweight, and the
            // thing that stops the arm reading as a stray line.
            let tail = CGPoint(x: pivot.x + dx / length * side * 0.1, y: pivot.y + dy / length * side * 0.1)

            ZStack {
                Path { path in
                    path.move(to: tail)
                    path.addLine(to: needle)
                }
                .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: max(1, side * 0.045), lineCap: .round))

                Circle()
                    .fill(.white.opacity(0.9))
                    .frame(width: side * 0.1, height: side * 0.1)
                    .position(pivot)

                Circle()
                    .fill(.white)
                    .frame(width: side * 0.07, height: side * 0.07)
                    .position(needle)
            }
            .shadow(color: .black.opacity(0.45), radius: side * 0.02, y: side * 0.01)
        }
    }
}

/// Two decks and a crossfader: what Auto DJ is doing, while it does it.
///
/// The fader is not decoration — it sits where the mix actually is, so a glance
/// says both that this is a mix and how much of it is left. The arms sit at
/// different points on their records for the same reason: one is near its
/// run-out, the other has just been dropped.
struct MixDecks: View {
    let progress: Double
    var size: CGFloat = 34

    var body: some View {
        HStack(spacing: 8) {
            Turntable(isSpinning: true, progress: 0.82, tint: .accentColor)
                .frame(width: size, height: size)
                .opacity(1 - progress * 0.55)

            VStack(spacing: 3) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: size * 0.9, height: 3)
                    .overlay(alignment: .leading) {
                        Circle()
                            .fill(.tint)
                            .frame(width: 7, height: 7)
                            .offset(x: (size * 0.9 - 7) * progress)
                    }
            }

            Turntable(isSpinning: true, progress: 0.12, tint: .accentColor)
                .frame(width: size, height: size)
                .opacity(0.45 + progress * 0.55)
        }
        .animation(.linear(duration: 0.1), value: progress)
    }
}
