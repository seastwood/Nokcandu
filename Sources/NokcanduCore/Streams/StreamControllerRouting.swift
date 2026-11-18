import Foundation

/// One snapshot decides mapping, physical reader and host identity together. Resolving never rewrites the
/// saved stream's controller profile; stopping Use Everywhere restores that choice immediately.
public struct StreamControllerRouting: Equatable {
    public let settings: StreamProfile.Controller
    public let usesEverywhere: Bool
    public let readsSteam: Bool
    public let presentedController: PresentedController?

    public init(settings saved: StreamProfile.Controller, everywhereID: String?, profilesEnabled: Bool,
                profiles: [PadProfiles.Profile]) {
        let everywhere = profilesEnabled && saved.allowEverywhereOverride
            ? everywhereID.flatMap { id in profiles.first { $0.id == id } } : nil
        let chosen = everywhere ?? saved.profileID.flatMap { id in profiles.first { $0.id == id } }
        var resolved = saved
        resolved.profileID = chosen?.id
        settings = resolved
        usesEverywhere = everywhere != nil
        readsSteam = chosen.map { PadProfiles.top($0, all: profiles, \.controllerSource) == .steamUSB } ?? false
        presentedController = chosen.flatMap { PadProfiles.top($0, all: profiles, \.presentAs) }
    }
}
