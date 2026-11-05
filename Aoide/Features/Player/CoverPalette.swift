import MeleteKit
import os
import SwiftUI

/// Albums' cover palettes, as Melete works them out: the cover's main colours,
/// the most of it first. Asked for once per album a run; a palette the server
/// hasn't worked out yet, or a failed read, is asked for again next time.
actor CoverPalettes {
    static let shared = CoverPalettes()

    private var known: [String: [Color]] = [:]
    private var inFlight: [String: Task<[Color], Never>] = [:]
    private let log = Logger(subsystem: AppIdentity.bundle, category: "palette")

    /// The album's palette; empty when it has none yet or it couldn't be read.
    func palette(forAlbum albumId: String, client: MeleteClient) async -> [Color] {
        if let palette = known[albumId] { return palette }
        if let running = inFlight[albumId] { return await running.value }
        let task = Task<[Color], Never> {
            do {
                let hexes = try await client.album(id: albumId).album.palette ?? []
                return hexes.compactMap(Color.init(hex:))
            } catch {
                log.error("Palette for \(albumId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return []
            }
        }
        inFlight[albumId] = task
        let palette = await task.value
        inFlight[albumId] = nil
        if !palette.isEmpty { known[albumId] = palette }
        return palette
    }
}

extension Color {
    /// `#rrggbb`, as Melete writes colours; nil for anything else.
    init?(hex: String) {
        guard hex.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// The ground under the full player's square cover, from the cover's palette: a
/// soft mesh of its main colours, the main one up top where it meets the cover,
/// the others below. Still, so it costs nothing while the song plays.
struct PaletteGround: View {
    let palette: [Color]

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.55], [0.5, 0.5], [1, 0.45],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: Self.colours(from: palette)
        )
    }

    /// Nine colours for the mesh from up to five: the first across the top,
    /// the rest woven below, repeated when there are fewer.
    static func colours(from palette: [Color]) -> [Color] {
        guard let main = palette.first else { return Array(repeating: .black, count: 9) }
        let rest = palette.count > 1 ? Array(palette.dropFirst()) : [main]
        func pick(_ index: Int) -> Color { rest[index % rest.count] }
        return [
            main, main, main,
            pick(0), main, pick(1),
            pick(2), pick(1), pick(3),
        ]
    }
}
