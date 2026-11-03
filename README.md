# DELG Trace Swift SDK

Public Swift Package Manager distribution for DELG Trace. The package exposes
the `DELGTrace` product and supports iOS 13+ and macOS 12+.

It uses Foundation, CryptoKit, and URLSession without third-party dependencies.
The SDK captures only events requested by the application and keeps a bounded
offline queue.

## Install

In Xcode, choose **File → Add Package Dependencies**, enter this repository URL,
and select the exact version `0.2.0` and product `DELGTrace`:

```text
https://github.com/DELG-Software/DELG-Trace-Swift.git
```

For a `Package.swift` consumer, add the package with an exact version requirement:

```swift
.package(
    url: "https://github.com/DELG-Software/DELG-Trace-Swift.git",
    exact: "0.2.0"
)
```

The source archive is also available at
[DELG-Trace-Swift-0.2.0.zip](https://pkg.delg.dev/trace/swift/DELG-Trace-Swift-0.2.0.zip)
(SHA-256 `85d70b43e8f0458fbc371b6dd5f4916dc66351700ba2834aa3a895c5a11bc3b4`).
See the [release manifest](https://pkg.delg.dev/trace/sdk/0.2.0/manifest.json)
and [SHA256SUMS](https://pkg.delg.dev/trace/sdk/0.2.0/SHA256SUMS) for all
published artifact hashes.

Versioned package releases are published as immutable Git tags in this repository.
