# DELG Trace Swift SDK

Public Swift Package Manager distribution for DELG Trace. The package exposes
the `DELGTrace` product and supports iOS 13+ and macOS 12+.

It uses Foundation, CryptoKit, and URLSession without third-party dependencies.
The SDK captures only events requested by the application and keeps a bounded
offline queue.

## Install

In Xcode, choose **File → Add Package Dependencies**, enter this repository URL,
and select the exact version `0.1.0` and product `DELGTrace`:

```text
https://github.com/DELG-Software/DELG-Trace-Swift.git
```

For a `Package.swift` consumer, add the package with an exact version requirement:

```swift
.package(
    url: "https://github.com/DELG-Software/DELG-Trace-Swift.git",
    exact: "0.1.0"
)
```

The source archive is also available at
[DELG-Trace-Swift-0.1.0.zip](https://pkg.delg.dev/trace/swift/DELG-Trace-Swift-0.1.0.zip)
(SHA-256 `88a1e76979f39de761fd8d10fe581838d85fbd73ae17126ca3290744da727204`).
See the [release manifest](https://pkg.delg.dev/trace/sdk/0.1.0/manifest.json)
and [SHA256SUMS](https://pkg.delg.dev/trace/sdk/0.1.0/SHA256SUMS) for all
published artifact hashes.

Versioned package releases are published as immutable Git tags in this repository.
