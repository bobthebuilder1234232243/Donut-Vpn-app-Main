//
//  FilePath.swift
//  SingBoxPacketTunnel
//
//  Created by GFWFighter on 7/25/1402 AP.
//

import Foundation

public enum FilePath {
    public static let packageName = {
        Bundle.main.infoDictionary?["BASE_BUNDLE_IDENTIFIER"] as? String ?? "unknown"
    }()
}

public extension FilePath {
    static let groupName = "group.\(packageName)"

    /// Resolves the shared App Group container, falling back to the app's own
    /// Application Support directory when the group is not provisioned.
    ///
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returns `nil` when the
    /// App Group entitlement is missing or was not granted by the signing profile
    /// (development, enterprise or TrollStore). Force-unwrapping that value traps at
    /// launch with EXC_BREAKPOINT / SIGTRAP, so the app degrades gracefully instead.
    static let sharedDirectory: URL = {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupName) {
            return container
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        NSLog("[DonutVPN] App Group %@ is unavailable; falling back to %@", groupName, fallback.path)
        return fallback
    }()

    static let cacheDirectory = sharedDirectory
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Caches", isDirectory: true)

    static let workingDirectory = cacheDirectory.appendingPathComponent("Working", isDirectory: true)
}

public extension URL {
    var fileName: String {
        var path = relativePath
        if let index = path.lastIndex(of: "/") {
            path = String(path[path.index(index, offsetBy: 1)...])
        }
        return path
    }
}
