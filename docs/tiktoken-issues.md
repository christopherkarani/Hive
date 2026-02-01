# TiktokenSwift build/link failure (git-lfs)

## Summary
Running `swift test` in `libs/hive` can fail at link time because `TiktokenSwift` stores its `TiktokenFFI.xcframework` binary as Git LFS pointers, and SwiftPM does not automatically run `git lfs pull` in the checkout.

## Repro
```sh
cd libs/hive
swift test
```

## Error (excerpt)
```
ld: unknown file type in '.../.build/.../TiktokenFFI.framework/TiktokenFFI'
.../TiktokenFFI.framework/TiktokenFFI: ASCII text
version https://git-lfs.github.com/spec/v1
```

## Impact
- `swift test` builds but fails when linking `TiktokenFFI` (because it's an LFS pointer, not a Mach-O binary).

## Notes
- The LFS objects may exist upstream, but SwiftPM's checkout uses git without automatically fetching LFS objects.
- SwiftPM surfaced additional warnings about duplicate package identity for `wax` and `conduit` via mixed local/remote dependencies, but those are warnings (not the root cause).

## Fix (local dev)
After `swift test` (or `swift build`) has created the checkout:

```sh
cd libs/hive/.build/checkouts/TiktokenSwift
git remote set-url origin https://github.com/christopherkarani/TiktokenSwift.git
git lfs pull
```

Then re-run:

```sh
cd libs/hive
swift package clean
swift test
```

## Potential long-term fixes
1. Convert `TiktokenFFI.xcframework` to a SwiftPM `binaryTarget` (url + checksum) so SwiftPM fetches a real binary artifact.
2. Vendor a small script/CI step that runs `git lfs pull` for checkouts that contain LFS pointers (e.g. `TiktokenSwift`).
