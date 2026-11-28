public import UniformTypeIdentifiers

extension UTType {
    /// A Folio video project (`.folio-video`): JSON, declared as an exported type in
    /// Info.plist. Declared here too so code never spells the identifier twice.
    public nonisolated static let folioVideoProject = UTType(exportedAs: "app.folio.video-project", conformingTo: .json)
}
