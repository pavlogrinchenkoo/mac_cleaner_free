/// All translation tables, one file per area so they can be edited independently.
enum Translations {
    /// English text -> Ukrainian.
    static let uk: [String: String] = {
        var merged: [String: String] = [:]
        for table in [GeneralStrings.uk, UIStrings.uk, ScanningStrings.uk, CleaningStrings.uk, DiagnosticsStrings.uk] {
            merged.merge(table) { first, _ in first }
        }
        return merged
    }()

    /// The individual tables, for the consistency tests.
    static let tables: [(name: String, strings: [String: String])] = [
        ("General", GeneralStrings.uk), ("UI", UIStrings.uk), ("Scanning", ScanningStrings.uk),
        ("Cleaning", CleaningStrings.uk), ("Diagnostics", DiagnosticsStrings.uk),
    ]
}
