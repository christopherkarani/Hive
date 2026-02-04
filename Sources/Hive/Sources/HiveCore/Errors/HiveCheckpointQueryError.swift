/// Errors related to optional checkpoint query capabilities.
public enum HiveCheckpointQueryError: Error, Sendable {
    /// The configured checkpoint store does not support the requested query operation.
    case unsupported
}

