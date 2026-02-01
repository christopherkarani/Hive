# TiktokenSwift checkout failure (git-lfs)

## Summary
Running `swift test` in `libs/hive` fails while checking out the `TiktokenSwift` dependency due to a missing Git LFS object. This blocks test execution and dependency resolution for the workspace.

## Repro
```sh
cd libs/hive
swift test
```

## Error (excerpt)
```
error: 'tiktokenswift': Couldn’t check out revision ‘661c349ebdc5e90c29f855e8c19f8984d401863b’:
    Downloading Sources/TiktokenFFI/TiktokenFFI.xcframework/ios-arm64/TiktokenFFI.framework/TiktokenFFI (34 MB)
    Error downloading object: Sources/TiktokenFFI/TiktokenFFI.xcframework/ios-arm64/TiktokenFFI.framework/TiktokenFFI (f458581): Smudge error: Error downloading ... remote missing object ...
    error: external filter 'git-lfs filter-process' failed
    fatal: ... smudge filter lfs failed
```

## Impact
- `swift test` fails before build planning completes.
- Any workflow that resolves `TiktokenSwift` via SwiftPM cannot proceed.

## Notes
- The failure indicates the referenced LFS object is missing from the remote.
- SwiftPM surfaced additional warnings about duplicate package identity for `wax` and `conduit` via mixed local/remote dependencies, but those are warnings (not the root cause).

## Potential fixes
1. Verify the `TiktokenSwift` repository LFS objects are available (re-push LFS objects for the pinned revision).
2. Pin to a revision or tag where LFS objects are known to exist.
3. If local dev only, mirror the repo with LFS objects and update the dependency URL to the local path.
4. Confirm Git LFS is installed and configured in the environment (if not already).
