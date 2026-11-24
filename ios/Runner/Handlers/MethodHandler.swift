//
//  MethodHandler.swift
//  Runner
//
//  Created by GFWFighter on 10/23/23.
//

import Foundation
import Flutter
import Combine
import Darwin
import DonutCore

public class MethodHandler: NSObject, FlutterPlugin {
    
    private var cancelBag: Set<AnyCancellable> = []
    
    public static let name = "\(Bundle.main.serviceIdentifier)/method"
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: Self.name, binaryMessenger: registrar.messenger())
        let instance = MethodHandler()
        registrar.addMethodCallDelegate(instance, channel: channel)
        instance.channel = channel
    }
    
    private var channel: FlutterMethodChannel?
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        @Sendable func mainResult(_ res: Any?) async -> Void {
            await MainActor.run {
                result(res)
            }
        }
        
        switch call.method {
        case "get_grpc_server_public_key":
            result("")
        case "add_grpc_client_public_key":
            result("")
        case "parse_config":
            guard
                let args = call.arguments as? [String:Any?],
                let path = args["path"] as? String,
                let tempPath = args["tempPath"] as? String,
                let debug = (args["debug"] as? NSNumber)?.boolValue
            else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
            var error: NSError?
            //MobileParse(path, tempPath, debug, &error)
            if let error {
                result(FlutterError(code: String(error.code), message: error.description, details: nil))
                return
            }
            result("")
        case "change_donut_options":
            guard let options = call.arguments as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
            VPNConfig.shared.configOptions = options
            result(true)
        case "setup":
                Task {
                    guard let args = call.arguments as? [String: Any?] else {
                        result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                        return
                    }
                    // Under TrollStore the App Group container is not provisioned, so
                    // fall back to the app's own directories exactly like
                    // FilePath.sharedDirectory does. The core start must never be
                    // skipped because a shared path is unavailable.
                    let baseDir = (args["baseDir"] as? String) ?? FilePath.sharedDirectory.path
                    let workingDir = (args["workingDir"] as? String) ?? FilePath.workingDirectory.path
                    let tempDir = (args["tempDir"] as? String) ?? FilePath.cacheDirectory.path
                    guard let grpcPort = args["grpcPort"] as? Int else {
                        result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                        return
                    }

                    NSLog("[DonutVPN] starting core with dir: %@ (working: %@, temp: %@, listen: 127.0.0.1:%ld)",
                          baseDir, workingDir, tempDir, grpcPort)

                    // libbox.Setup and the core's stderr redirect assume these paths
                    // exist. When one is missing the gRPC listener silently never comes
                    // up, while MobileSetup still reports success.
                    let fileManager = FileManager.default
                    let coreDirectories = [
                        baseDir,
                        workingDir,
                        tempDir,
                        URL(fileURLWithPath: workingDir).appendingPathComponent("data").path
                    ]
                    for directory in coreDirectories {
                        do {
                            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
                        } catch {
                            NSLog("[DonutVPN] cannot create core directory %@: %@", directory, error.localizedDescription)
                            result(FlutterError(code: "CORE_DIR", message: "cannot create \(directory): \(error.localizedDescription)", details: nil))
                            return
                        }
                    }
                    if !fileManager.changeCurrentDirectoryPath(baseDir) {
                        NSLog("[DonutVPN] warning: cannot enter %@", baseDir)
                    }
                    VPNConfig.shared.baseDir=baseDir
                    VPNConfig.shared.workingDir=workingDir
                    VPNConfig.shared.tempDir=tempDir
                    var error: NSError?
                    let opts = MobileSetupOptions()
                    opts.basePath = baseDir
                    opts.workingDir = workingDir
                    opts.tempDir = tempDir
                    opts.listen = "127.0.0.1:\(grpcPort)"
                    opts.secret = ""
                    opts.debug = false
                    opts.mode = 4
                    opts.fixAndroidStack = false
                    MobileSetup(opts,
                        nil,
                        &error
                    )
                    
                    if let error {
                        NSLog("[DonutVPN] core setup failed: %@", error.localizedDescription)
                        result(FlutterError(code: String(error.code), message: error.localizedDescription, details: nil))
                        return
                    }

                    guard await Self.waitUntilListening(port: grpcPort) else {
                        NSLog("[DonutVPN] core did not bind 127.0.0.1:%ld (base: %@)", grpcPort, baseDir)
                        result(FlutterError(
                            code: "CORE_NOT_LISTENING",
                            message: "core is not listening on 127.0.0.1:\(grpcPort); base=\(baseDir) working=\(workingDir)",
                            details: nil
                        ))
                        return
                    }
                    NSLog("[DonutVPN] core is listening on 127.0.0.1:%ld", grpcPort)

                    do {
                        try await VPNManager.shared.setup()
                    } catch {
                        result(FlutterError(code: "SETUP", message: error.localizedDescription, details: nil))
                        return
                    }
                    result(true)
                }
        case "start":
            Task {
                guard
                    let args = call.arguments as? [String:Any?],
                    let path = args["path"] as? String,
                    let name = args["name"] as? String,
                    let grpcPort=args["grpcPort"] as? Int
                else {
                    await mainResult(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                    return
                }
                VPNConfig.shared.activeConfigPath = path
                VPNConfig.shared.activeProfileName = name
                VPNConfig.shared.grpcServiceModePort=grpcPort
                
                var error: NSError?
                //let configstr=MobileBuildConfig(path,&error) as String
                if let error {
                    await mainResult(FlutterError(code: String(error.code), message: error.description, details: nil))
                    return
                }
                do {
                    try await VPNManager.shared.setup()
                    try await VPNManager.shared.connect(with: path, grpcServiceModePort: grpcPort, disableMemoryLimit: VPNConfig.shared.disableMemoryLimit)
                } catch {
                    await mainResult(FlutterError(code: "SETUP_CONNECTION", message: error.localizedDescription, details: nil))
                    return
                }
                await mainResult(true)
            }
//        case "restart":
//            Task { [unowned self] in
//                guard
//                    let args = call.arguments as? [String:Any?],
//                    let path = args["path"] as? String,
//                    let name = args["name"] as? String,
//                    let grpcPort=args["grpcPort"] as? Int
//                else {
//                    await mainResult(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
//                    return
//                }
//                VPNConfig.shared.activeConfigPath = path
//                VPNConfig.shared.activeProfileName = name
//                VPNConfig.shared.grpcServiceModePort=grpcPort
//                
//                
//                VPNManager.shared.disconnect()
//                await waitForStop().value
//                var error: NSError?
//                do {
//                    try await VPNManager.shared.setup()
//                    try await VPNManager.shared.connect(with: path, disableMemoryLimit: VPNConfig.shared.disableMemoryLimit)
//                } catch {
//                    await mainResult(FlutterError(code: "SETUP_CONNECTION", message: error.localizedDescription, details: nil))
//                    return
//                }
//                await mainResult(true)
//            }
        case "stop":
            VPNManager.shared.disconnect()
            result(true)
        case "reset":
            VPNManager.shared.reset()
            result(true)
        case "url_test":
            guard
                let args = call.arguments as? [String:Any?]
            else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
            let group = args["groupTag"] as? String
            FileManager.default.changeCurrentDirectoryPath(FilePath.sharedDirectory.path)
            do {
                try LibboxNewStandaloneCommandClient()?.urlTest(group)
            } catch {
                result(FlutterError(code: "URL_TEST", message: error.localizedDescription, details: nil))
                return
            }
            result(true)
        case "select_outbound":
            guard
                let args = call.arguments as? [String:Any?],
                let group = args["groupTag"] as? String,
                let outbound = args["outboundTag"] as? String
            else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
            FileManager.default.changeCurrentDirectoryPath(FilePath.sharedDirectory.path)
            do {
                try LibboxNewStandaloneCommandClient()?.selectOutbound(group, outboundTag: outbound)
            } catch {
                result(FlutterError(code: "SELECT_OUTBOUND", message: error.localizedDescription, details: nil))
                return
            }
            result(true)
        case "generate_config":
            guard
                let args = call.arguments as? [String:Any?],
                let path = args["path"] as? String
            else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
            var error: NSError?
//            let config = MobileBuildConfig(path, VPNConfig.shared.configOptions, &error)
//            if let error {
//                result(FlutterError(code: "BUILD_CONFIG", message: error.localizedDescription, details: nil))
//                return
//            }
//            result(config)
        case "generate_warp_config":
            guard let args = call.arguments as? [String: Any],
                  let licenseKey = args["license-key"] as? String,
                  let accountId = args["previous-account-id"] as? String,
                  let accessToken = args["previous-access-token"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                return
            }
//            let warpConfig = MobileGenerateWarpConfig(licenseKey, accountId, accessToken, nil)
//            result(warpConfig)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    /// The core binds synchronously inside `MobileSetup`, but a failure in
    /// `libbox.Setup` is swallowed by its panic recovery, so confirm the port is
    /// really held before reporting success to Dart.
    private static func waitUntilListening(port: Int, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isPortInUse(port) { return true }
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
        }
        return isPortInUse(port)
    }

    /// A bind probe (not a connect probe): it never opens a client session against the core.
    private static func isPortInUse(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { _ = close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc != 0 && errno == EADDRINUSE
    }

    private func waitForStop() -> Future<Void, Never> {
        return Future { promise in
            var cancellable: AnyCancellable? = nil
            cancellable = VPNManager.shared.$state
                .filter { $0 == .disconnected }
                .first()
                .delay(for: 0.5, scheduler: RunLoop.current)
                .sink(receiveValue: { _ in
                    promise(.success(()))
                    cancellable?.cancel()
                })
        }
    }
}
