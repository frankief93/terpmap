import Foundation
import SwiftUI

/// Selected look + user dial overrides, persisted across launches.
final class LookStore: ObservableObject {
    static let shared = LookStore()

    @AppStorage("selectedLookID") private var selectedLookID = "natural"
    @AppStorage("lookIntensity") var intensityRaw: Double = 1.0

    @Published var overrides = Overrides()

    struct Overrides: Codable, Equatable {
        var ev: Double?
        var contrast: Double?
        var saturation: Double?
        var warmth: Double?
        var fade: Double?
        var grain: Double?
        var vignette: Double?
        var halation: Double?
    }

    var selectedLook: FilmLook {
        FilmLook.all.first { $0.id == selectedLookID } ?? FilmLook.all[0]
    }

    /// The look with user overrides merged in.
    var effectiveLook: FilmLook {
        var look = selectedLook
        let o = overrides
        if let v = o.ev { look.ev = v }
        if let v = o.contrast { look.contrast = v }
        if let v = o.saturation { look.saturation = v }
        if let v = o.warmth { look.warmth = v }
        if let v = o.fade { look.fade = v }
        if let v = o.grain { look.grain = v }
        if let v = o.vignette { look.vignette = v }
        if let v = o.halation { look.halation = v }
        return look
    }

    func select(_ look: FilmLook) {
        selectedLookID = look.id
        overrides = Overrides()
        objectWillChange.send()
    }
}
