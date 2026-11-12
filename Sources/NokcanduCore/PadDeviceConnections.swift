/// Session identities for additional device slots; a replacement is a disconnect too.
public struct PadDeviceConnections {
    private var identities: [Int: String] = [:]
    public init() {}
    public mutating func update(_ connected: [Int: String]) -> [Int] {
        let lost = identities.keys.filter { identities[$0] != connected[$0] }.sorted()
        identities = connected
        return lost
    }
}
