import Foundation

extension PadProfiles {
    /// Copies a layer's explicit settings, with private copies of its referenced
    /// macros and menus. Destination base behavior and assignments stay intact.
    public static func importingLayer(from source: Profile, layerID: String, into destination: Profile, all: [Profile]) throws -> Profile {
        guard let original = source.layers.first(where: { $0.id == layerID }) else { throw NokError("That layer is no longer available.") }
        guard merged(destination, all: all).layers.count < 8 else { throw NokError("A profile can use up to eight layers. Remove a layer before importing another.") }
        var result = destination
        let names = Set(merged(destination, all: all).layers.map { $0.name.lowercased() })
        var name = original.name, suffix = 2
        while names.contains(name.lowercased()) { name = original.name + " (\(suffix))"; suffix += 1 }
        let sourceMacros = collected(source, all: all, \.macros)
        let sourceMenus = collected(source, all: all, \.menus)
        let deviceIDs = Set(devices(destination, all: all).map(\.id))
        var macroIDs: [String: String] = [:], menuIDs: [String: String] = [:]
        func layerName(_ value: String) throws -> String {
            if value.caseInsensitiveCompare(original.name) == .orderedSame { return name }
            guard names.contains(value.lowercased()) else {
                throw NokError("This layer also uses the “\(value)” layer. Add that layer to this profile before importing.")
            }
            return value
        }
        func outputs(_ values: [Output]) throws -> [Output] { try values.map(output) }
        func output(_ value: Output) throws -> Output {
            switch value {
            case .layerHold(let n): return .layerHold(try layerName(n))
            case .layerToggle(let n): return .layerToggle(try layerName(n))
            case .macro(let id):
                if let mapped = macroIDs[id] { return .macro(mapped) }
                guard var macro = sourceMacros.first(where: { $0.id == id }) else { throw NokError("A macro used by this layer is missing from its source profile.") }
                let fresh = UUID().uuidString; macroIDs[id] = fresh; macro.id = fresh
                for i in macro.steps.indices {
                    if let v = macro.steps[i].output { macro.steps[i].output = try output(v) }
                    if let v = macro.steps[i].outputs { macro.steps[i].outputs = try outputs(v) }
                }
                result.macros = (result.macros ?? []) + [macro]
                return .macro(fresh)
            case .menu(let id):
                if let mapped = menuIDs[id] { return .menu(mapped) }
                guard var menu = sourceMenus.first(where: { $0.id == id }) else { throw NokError("A radial menu used by this layer is missing from its source profile.") }
                let fresh = UUID().uuidString; menuIDs[id] = fresh; menu.id = fresh
                for i in menu.slices.indices { menu.slices[i].outputs = try outputs(menu.slices[i].outputs) }
                result.menus = (result.menus ?? []) + [menu]
                return .menu(fresh)
            default: return value
            }
        }
        var copy = original; copy.id = UUID().uuidString; copy.name = name
        for (key, binding) in original.bindings {
            if key.hasPrefix("dev.") {
                guard deviceIDs.contains(where: { key.hasPrefix("dev.\($0).") }) else {
                    throw NokError("This layer uses an extra device that is not in this profile. Add the same device before importing.")
                }
            }
            var b = binding
            b.press = try outputs(b.press); b.tap = try outputs(b.tap)
            b.hold = try outputs(b.hold); b.double = try outputs(b.double)
            b.togetherOutputs = try outputs(b.togetherOutputs)
            copy.bindings[key] = b
        }
        guard collected(result, all: all, \.macros).count <= 16,
              collected(result, all: all, \.menus).count <= 8 else {
            throw NokError("Importing this layer would exceed the limit of sixteen macros or eight radial menus.")
        }
        result.layers.append(copy)
        return result
    }
}
