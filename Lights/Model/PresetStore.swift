import Foundation
import LightsKit
import Observation

/// The user's presets. Applying one goes through the light store like a change made by hand, so
/// adaptive lighting steps aside for the lights it sets.
@Observable
final class PresetStore {
    private(set) var presets: [Preset]

    @ObservationIgnored private unowned let store: LightStore
    @ObservationIgnored private let defaults: UserDefaults
    /// Told when a preset is deleted, so its shortcut goes with it.
    @ObservationIgnored var onDelete: ((Preset) -> Void)?

    private static let defaultsKey = "presets"

    /// Icons offered for presets; new presets take the first one not in use.
    static let symbols: [(name: String, title: String)] = [
        ("star.fill", "Star"), ("heart.fill", "Heart"), ("sparkles", "Sparkles"), ("bolt.fill", "Bolt"),
        ("flame.fill", "Flame"), ("leaf.fill", "Leaf"), ("moon.fill", "Moon"), ("sun.max.fill", "Sun"),
        ("video.fill", "Video"), ("scope", "Focus"), ("sofa.fill", "Sofa"), ("gamecontroller.fill", "Game controller"),
        ("book.fill", "Book"), ("music.note", "Music"), ("headphones", "Headphones"), ("film.fill", "Film"),
        ("cup.and.saucer.fill", "Coffee"), ("paintpalette.fill", "Palette"), ("desktopcomputer", "Computer"), ("bed.double.fill", "Bed"),
    ]

    init(store: LightStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey), let saved = try? JSONDecoder().decode([Preset].self, from: data) {
            presets = saved
        } else {
            presets = Preset.builtIn
        }
    }

    func preset(id: UUID) -> Preset? {
        presets.first { $0.id == id }
    }

    /// Whether the lights show the preset right now.
    func isActive(_ preset: Preset) -> Bool {
        preset.matches(store.lights.map(\.state))
    }

    func apply(_ preset: Preset) {
        for light in store.lights {
            for step in preset.steps(for: light.state) {
                switch step {
                case .power(let on): store.setPower(on, for: light)
                case .kelvin(let kelvin): store.setKelvin(kelvin, for: light)
                case .color(let color): store.setColor(color, for: light)
                case .scene(let name): store.setEffect(name, for: light)
                case .brightness(let brightness): store.setBrightness(brightness, for: light)
                }
            }
        }
    }

    // MARK: Editing

    /// Saves what the lights show now as a new preset.
    @discardableResult
    func saveCurrentLights(named name: String) -> Preset {
        let symbol = Self.symbols.map(\.name).first { symbol in !presets.contains { $0.symbol == symbol } } ?? "star.fill"
        let preset = Preset(capturing: store.lights.map(\.state), name: name, symbol: symbol)
        presets.append(preset)
        save()
        return preset
    }

    /// Takes what the lights the preset sets show now; lights it leaves alone stay left out.
    func updateToCurrentLights(_ preset: Preset) {
        var preset = preset
        let lights = store.lights.map(\.state)
        for light in lights where light.isReachable && preset.look(for: light) != nil {
            preset.setLook(Preset.Look(showing: light), forLight: light.id, among: lights)
        }
        update(preset)
    }

    /// Sets what the preset does with one light; nil leaves the light out.
    func setLook(_ look: Preset.Look?, for light: Light, in preset: Preset) {
        var preset = preset
        preset.setLook(look, forLight: light.id, among: store.lights.map(\.state))
        update(preset)
    }

    /// Saves a renamed or otherwise edited preset.
    func update(_ preset: Preset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }), presets[index] != preset else { return }
        presets[index] = preset
        save()
    }

    func delete(_ preset: Preset) {
        presets.removeAll { $0.id == preset.id }
        save()
        onDelete?(preset)
    }

    func move(_ preset: Preset, by offset: Int) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        let destination = index + offset
        guard presets.indices.contains(destination) else { return }
        presets.swapAt(index, destination)
        save()
    }

    var missingBuiltIns: [Preset] {
        Preset.builtIn.filter { builtIn in !presets.contains { $0.id == builtIn.id } }
    }

    func restoreBuiltIns() {
        presets += missingBuiltIns
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(presets), forKey: Self.defaultsKey)
    }
}
