/// Namespace for the Hive framework version information.
public enum HiveVersion {
    /// Semantic version string for the Hive umbrella module.
    public static let string = "0.0.0"

    /// Semantic version string for HiveCore.
    public static let core = "0.0.0"

    /// Semantic version string for HiveDSL.
    public static let dsl = "0.0.0"

    /// Semantic version string for HiveConduit.
    public static let conduit = "0.0.0"

    /// Semantic version string for HiveCheckpointWax.
    public static let checkpointWax = "0.0.0"

    /// Semantic version string for HiveRAGWax.
    public static let ragWax = "0.0.0"

    /// All module versions as a dictionary.
    public static var all: [String: String] {
        [
            "umbrella": string,
            "core": core,
            "dsl": dsl,
            "conduit": conduit,
            "checkpointWax": checkpointWax,
            "ragWax": ragWax
        ]
    }
}

// MARK: - Deprecated Module-Specific Version Types

/// Deprecated: Use `HiveVersion.core` instead.
@available(*, deprecated, renamed: "HiveVersion")
public enum HiveCoreVersion {
    /// Deprecated: Use `HiveVersion.core` instead.
    @available(*, deprecated, renamed: "HiveVersion.core")
    public static let string = HiveVersion.core
}
