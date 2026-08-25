import SwiftUI
import SwiftData

@main
struct FreeDVApp: App {
    let container: ModelContainer
    
    init() {
        let schema = Schema([
            ReceptionSession.self,
            SignalSnapshot.self,
            SyncEvent.self,
            CallsignEvent.self
        ])
        let config = ModelConfiguration(
            "ReceptionLog",
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            // The persistent store can be unavailable at launch — e.g. the app
            // is started (or prewarmed) while the device is still locked and
            // the data container is inaccessible, or the store is corrupted.
            // Never hard-crash the launch: fall back to an in-memory store so
            // the app opens; reception logging persists again on next launch.
            appLog("ModelContainer failed (\(error)) — falling back to in-memory store")
            let memoryConfig = ModelConfiguration(
                "ReceptionLog",
                schema: schema,
                isStoredInMemoryOnly: true
            )
            do {
                container = try ModelContainer(for: schema, configurations: memoryConfig)
            } catch {
                fatalError("Failed to create in-memory ModelContainer: \(error)")
            }
        }
    }
    
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                appLog("App: foreground (active)")
            case .inactive:
                appLog("App: inactive")
            case .background:
                appLog("App: background — audio continues if RX is running")
            @unknown default:
                break
            }
        }
    }
}
