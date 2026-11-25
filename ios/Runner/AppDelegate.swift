import UIKit
import Flutter
import DonutCore
import Sentry
@main
@objc class AppDelegate: FlutterAppDelegate {
    
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Printed before any Flutter work so a stale IPA is identifiable from
        // syslog even when the Dart side never reaches bootstrap.
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        NSLog("[DonutVPN] PROVENANCE v%@+%@ ports=17078/17079 ownership-guard=ON icon-root-fix=ON profile-idempotent=ON",
              shortVersion, buildNumber)
        setupFileManager()
        registerHandlers()
        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    
    func setupFileManager() {
        try? FileManager.default.createDirectory(at: FilePath.workingDirectory, withIntermediateDirectories: true)
        FileManager.default.changeCurrentDirectoryPath(FilePath.sharedDirectory.path)
    }
    
    func registerHandlers() {
        MethodHandler.register(with: self.registrar(forPlugin: MethodHandler.name)!)
        PlatformMethodHandler.register(with: self.registrar(forPlugin: PlatformMethodHandler.name)!)
        FileMethodHandler.register(with: self.registrar(forPlugin: FileMethodHandler.name)!)
        StatusEventHandler.register(with: self.registrar(forPlugin: StatusEventHandler.name)!)
        AlertsEventHandler.register(with: self.registrar(forPlugin: AlertsEventHandler.name)!)
//        LogsEventHandler.register(with: self.registrar(forPlugin: LogsEventHandler.name)!)
//        GroupsEventHandler.register(with: self.registrar(forPlugin: GroupsEventHandler.name)!)
//        ActiveGroupsEventHandler.register(with: self.registrar(forPlugin: ActiveGroupsEventHandler.name)!)
//        StatsEventHandler.register(with: self.registrar(forPlugin: StatsEventHandler.name)!)
    }
}

