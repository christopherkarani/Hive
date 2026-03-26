@_exported import HiveCore

// MARK: - Deprecated Version Type

/// Deprecated: Use `HiveVersion.conduit` instead.
@available(*, deprecated, renamed: "HiveVersion")
public enum HiveConduitVersion {
    /// Deprecated: Use `HiveVersion.conduit` instead.
    @available(*, deprecated, renamed: "HiveVersion.conduit")
    public static let string = HiveVersion.conduit
}
