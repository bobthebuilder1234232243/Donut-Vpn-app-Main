//
//  VPNManager.swift
//  Runner
//
//  Created by GFWFighter on 7/25/1402 AP.
//

import Foundation
import Combine
import NetworkExtension

enum VPNManagerAlertType: String {
    case RequestVPNPermission
    case RequestNotificationPermission
    case EmptyConfiguration
    case StartCommandServer
    case CreateService
    case StartService
}

struct VPNManagerAlert {
    let alert: VPNManagerAlertType?
    let message: String?
}

class VPNManager: ObservableObject {
    private var cancelBag: Set<AnyCancellable> = []
    
    private var observer: NSObjectProtocol?
    /// Only ever points at this app's own tunnel configuration. `nil` until
    /// `loadVPNPreference()` has verified ownership, so a configuration that
    /// belongs to another app can never be saved or stopped.
    private var manager: NEVPNManager?
    private var loaded: Bool = false
    private var timer: Timer?
            
    static let shared: VPNManager = VPNManager()

    /// Bundle identifier of the Packet Tunnel provider shipped with this app.
    /// Ownership is matched on this value - never on the display name - because
    /// `loadAllFromPreferences()` and `NEVPNManager.shared()` can surface
    /// configurations that other apps created (observed under TrollStore).
    private static var providerBundleIdentifier: String {
        Bundle.main.baseBundleIdentifier + ".DonutPacketTunnel"
    }

    private func isOwnConfiguration(_ candidate: NEVPNManager) -> Bool {
        guard let proto = candidate.protocolConfiguration as? NETunnelProviderProtocol else { return false }
        return proto.providerBundleIdentifier == Self.providerBundleIdentifier
    }
        
    @Published private(set) var state: NEVPNStatus = .invalid
    @Published private(set) var alert: VPNManagerAlert = .init(alert: nil, message: nil)
    
    @Published private(set) var upload: Int64 = 0
    @Published private(set) var download: Int64 = 0
    @Published private(set) var elapsedTime: TimeInterval = 0
    
    private var _connectTime: Date?
    private var connectTime: Date? {
        set {
            UserDefaults(suiteName: FilePath.groupName)?.set(newValue?.timeIntervalSince1970, forKey: "SingBoxConnectTime")
            _connectTime = newValue
        }
        get {
            if let _connectTime {
                return _connectTime
            }
            guard let interval = UserDefaults(suiteName: FilePath.groupName)?.value(forKey: "SingBoxConnectTime") as? TimeInterval else {
                return nil
            }
            return Date(timeIntervalSince1970: interval)
        }
    }
    private var readingWS: Bool = false
    
    @Published var isConnectedToAnyVPN: Bool = false
    
    init() {
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: nil) { [weak self] notification in
            guard let connection = notification.object as? NEVPNConnection else { return }
            self?.state = connection.status
        }
        
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            updateStats()
            elapsedTime = -1 * (connectTime?.timeIntervalSinceNow ?? 0)
        }
    }
                
    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        timer?.invalidate()
    }
    
    func setup() async throws {
        // guard !loaded else { return }
        loaded = true
        do {
            try await loadVPNPreference()
        } catch {
            print(error.localizedDescription)
        }
    }
    
    private func loadVPNPreference() async throws {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            // Adopt only the configuration this app owns. Taking `managers.first`
            // picked up other apps' tunnels (Proton VPN), and later saves/stops then
            // hit "permission denied" and sent stop commands to that tunnel.
            let foreign = managers.filter { !isOwnConfiguration($0) }
            if !foreign.isEmpty {
                NSLog("[DonutVPN] ignoring %ld VPN configuration(s) owned by other apps", foreign.count)
            }
            if let own = managers.first(where: { isOwnConfiguration($0) }) {
                self.manager = own
                return
            }
            NSLog("[DonutVPN] saving own configuration %@", Self.providerBundleIdentifier)
            let newManager = NETunnelProviderManager()
            let `protocol` = NETunnelProviderProtocol()
            `protocol`.providerBundleIdentifier = Self.providerBundleIdentifier
            `protocol`.serverAddress = "localhost"
            newManager.protocolConfiguration = `protocol`
            newManager.localizedDescription = "Donut VPN"
            try await newManager.saveToPreferences()
            try await newManager.loadFromPreferences()
            self.manager = newManager
        } catch {
            // No provisioned App Group / VPN entitlement under TrollStore means this
            // save can legitimately fail. Leave manager nil: never fall back to a
            // configuration that belongs to another app.
            NSLog("[DonutVPN] failed to save own configuration: %@", error.localizedDescription)
            self.manager = nil	
        }
    }
    
    private func enableVPNManager() async throws {
        guard let manager, isOwnConfiguration(manager) else {
            throw NSError(
                domain: "DonutVPN",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "refusing to save a VPN configuration this app does not own"]
            )
        }
        manager.isEnabled = true
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        rule.probeURL = URL(string: "http://captive.apple.com")
        manager.onDemandRules = [rule]
        manager.isOnDemandEnabled = true
        
        NSLog("[DonutVPN] saving own configuration %@", Self.providerBundleIdentifier)
        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        } catch {
            // Surface the failure: connect() must abort before startVPNTunnel rather
            // than proceed with an unpersisted configuration.
            NSLog("[DonutVPN] refusing to save: %@", error.localizedDescription)
            throw error
        }
    }
    
    @MainActor private func set(upload: Int64, download: Int64) {
        self.upload = upload
        self.download = download
    }
    
    var isAnyVPNConnected: Bool {
        guard let cfDict = CFNetworkCopySystemProxySettings() else { return false }
        let nsDict = cfDict.takeRetainedValue() as NSDictionary
        guard let keys = nsDict["__SCOPED__"] as? NSDictionary else {
            return false
        }
        for key: String in keys.allKeys as! [String] {
            if key == "tap" || key == "tun" || key == "ppp" || key == "ipsec" || key == "ipsec0" {
                return true
            } else if key.starts(with: "utun") {
                return true
            }
        }
        return false
    }
    
    func reset() {
        loaded = false
        if state != .disconnected && state != .invalid {
            disconnect()
        }
        $state.filter { $0 == .disconnected || $0 == .invalid }.first().sink { [weak self] _ in
            Task { [weak self] () in
                guard let self else { return }
                // Never enumerate or remove VPN configurations: only this app's own
                // tunnel may be touched. Dropping the reference and reloading
                // re-resolves it by provider bundle identifier.
                self.manager = nil
                try? await self.loadVPNPreference()
            }
        }.store(in: &cancelBag)
        
    }
    
    
    private func updateStats() {
        let isAnyVPNConnected = self.isAnyVPNConnected
        if isConnectedToAnyVPN != isAnyVPNConnected {
            isConnectedToAnyVPN = isAnyVPNConnected
        }
        guard state == .connected else { return }
        guard let manager, isOwnConfiguration(manager),
              let connection = manager.connection as? NETunnelProviderSession else { return }
        do {
            try connection.sendProviderMessage("stats".data(using: .utf8)!) { [weak self] response in
                guard
                    let response,
                    let response = String(data: response, encoding: .utf8)
                else { return }
                let responseComponents = response.components(separatedBy: ",")
                guard
                    responseComponents.count == 2,
                    let upload = Int64(responseComponents[0]),
                    let download = Int64(responseComponents[1])
                else { return }
                Task { [upload, download, weak self] () in
                    await self?.set(upload: upload, download: download)
                }
            }
        } catch {
            print(error.localizedDescription)
        }
    }
    
    func connect(with config: String, grpcServiceModePort:Int, disableMemoryLimit: Bool = false) async throws {
        
        await set(upload: 0, download: 0)
//        guard state == .disconnected else { return }
        do {
            try await enableVPNManager()
            guard let manager, isOwnConfiguration(manager) else {
                NSLog("[DonutVPN] refusing to start: no VPN configuration owned by this app")
                throw NSError(
                    domain: "DonutVPN",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "no VPN configuration owned by this app"]
                )
            }
            try manager.connection.startVPNTunnel(options: [
                "Config": config as NSString,
                "GrpcServiceModePort":NSNumber(value: grpcServiceModePort),
                "DisableMemoryLimit": (disableMemoryLimit ? "YES" : "NO") as NSString,
            ])
            
        } catch {
            // Must reach Dart: the connect flow maps this to startFailed and shows the
            // single engine-failure toast instead of silently reporting success.
            NSLog("[DonutVPN] connect failed: %@", error.localizedDescription)
            throw error
        }
        connectTime = .now
    }
    
    func disconnect() {
        // Never stop a tunnel this app does not own: a foreign configuration here
        // makes iOS log "Received a stop command from Runner[PID]" in the other
        // app's session and fails with "permission denied" on save.
        guard let manager else {
            NSLog("[DonutVPN] disconnect skipped: no owned VPN configuration loaded")
            return
        }
        guard isOwnConfiguration(manager) else {
            NSLog("[DonutVPN] disconnect skipped: configuration %@ is not ours", manager.localizedDescription ?? "unknown")
            self.manager = nil
            return
        }
        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            manager.onDemandRules = []
            
            manager.saveToPreferences { error in
                if let error = error {
                    print("save error:", error)
                    return
                }
            }
        }

//        guard state == .connected else { return }
        NSLog("[DonutVPN] stopping own configuration only")
        manager.connection.stopVPNTunnel()
    }
}
