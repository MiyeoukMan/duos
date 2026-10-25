import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        _ = Library.shared
        _ = Settings.shared
        Library.shared.seedDemoOnce()
        ds_set_local_dir(Library.shared.supportDir.path)   // Nintendo WFC 설정(wfcsettings.bin)도 여기 — 게임을 켜기 전에도 설정 화면이 본다
        ds_net_set_log(Library.shared.wfcLogURL.path)   // 접속 기록 — 설정 › 인터넷(WFC) › 접속 기록
        Internet.shared.apply()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var console: ConsoleViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        if let preview = UserDefaults.standard.string(forKey: "DuoArtPreview") {
            window.rootViewController = ArtPreviewViewController(mode: preview)   // 그림 확인용
        } else {
            let c = ConsoleViewController()
            console = c
            window.rootViewController = c
        }
        window.makeKeyAndVisible()
        self.window = window
        if !connectionOptions.urlContexts.isEmpty { console?.open(connectionOptions.urlContexts.map { $0.url }) }
    }

    /// 파일 앱의 "DuoS로 열기" · 공유로 받은 ROM
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        console?.open(URLContexts.map { $0.url })
    }
}
