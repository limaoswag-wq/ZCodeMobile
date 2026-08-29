import SwiftUI
import UserNotifications

@main
struct ZCodeMobileApp: App {
    @StateObject private var settings = AppSettings()
    @Environment(\.scenePhase) private var scenePhase
    private let notifyDelegate = NotificationDelegate()

    var body: some Scene {
        WindowGroup {
            RootView(settings: settings)
                .onAppear {
                    UNUserNotificationCenter.current().delegate = notifyDelegate
                    LocalNotify.request()
                }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        UIApplication.shared.applicationIconBadgeNumber = 0
                        // 前台：网页自己持连接，停掉原生监控避免互踢。
                        MonitorController.shared.stop()
                        SilentAudio.shared.stop()
                    case .background:
                        if settings.keepAlive {
                            SilentAudio.shared.start()
                        }
                        MonitorController.shared.start()
                    default:
                        break
                    }
                }
        }
    }
}
