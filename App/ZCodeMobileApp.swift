import SwiftUI
import UIKit
import UserNotifications

@main
struct ZCodeMobileApp: App {
    @StateObject private var client = BridgeClient()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(client: client)
                .onAppear {
                    UNUserNotificationCenter.current().delegate = client.notifyDelegate
                    client.start()
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        UIApplication.shared.applicationIconBadgeNumber = 0
                        client.pollNow()
                        if client.settings.keepAlive { SilentAudio.shared.start() }
                    }
                }
        }
    }
}
