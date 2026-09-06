import AppKit

/// Which appearance the app forces, if any.
enum AppearanceSetting: String, CaseIterable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// nil means "stop overriding and inherit", which is exactly what
    /// NSApp.appearance wants for System -- the property is null_resettable, so
    /// nil is the documented way to clear it rather than a missing value.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Menu tag. Only ever used to get from a clicked item back to a case;
    /// what gets persisted is the raw string, so these numbers carry no
    /// compatibility weight.
    var tag: Int {
        switch self {
        case .system: 0
        case .light: 1
        case .dark: 2
        }
    }

    init?(tag: Int) {
        guard let match = Self.allCases.first(where: { $0.tag == tag }) else { return nil }
        self = match
    }
}
