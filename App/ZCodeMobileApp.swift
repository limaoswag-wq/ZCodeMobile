import SwiftUI
import UserNotifications

@main
struct ZCodeMobileApp: App {
    @StateObject private var app = AppState.shared
    @Environment(\.scenePhase) private var scenePhase
    private let notifyDelegate = NotificationDelegate()

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
                .onAppear {
                    UNUserNotificationCenter.current().delegate = notifyDelegate
                    LocalNotify.request()
                    app.connectSavedLinkIfNeeded()
                }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        UIApplication.shared.applicationIconBadgeNumber = 0
                        SilentAudio.shared.stop()
                    case .background:
                        // 原生连接前后台是同一条，不需要交接；保活只为 iOS 不杀进程。
                        if app.settings.keepAlive {
                            SilentAudio.shared.start()
                        }
                    default:
                        break
                    }
                }
        }
    }
}
