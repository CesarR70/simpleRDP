//
// App.swift — SwiftUI @main entry point.
//
// Window group owns the FavoritesStore as an @StateObject so the entire app
// shares the same favorites. The connect form drives RDPSession directly;
// rendering of the remote desktop is delegated to SessionView (currently a
// status placeholder until Milestone 2 wires up the framebuffer surface).
//

import SwiftUI

/// Housekeeping on quit: staged server→Mac clipboard files must not linger.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        ClipboardChannel.cleanClipboardCache()
    }
}

@main
struct simpleRDPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var favorites = FavoritesStore()

    var body: some Scene {
        WindowGroup("simpleRDP") {
            ContentView()
                .environmentObject(favorites)
                .frame(minWidth: 900, minHeight: 620)
        }
    }
}

struct ContentView: View {
    // The view model is owned here (not inside ConnectView) so the window can
    // swap between the connect form and the live session view on state change.
    @StateObject private var vm = SessionViewModel()

    var body: some View {
        if case .connected = vm.state {
            SessionView(state: vm.state,
                        framebuffer: vm.session.framebuffer,
                        input: vm.session.input,
                        clipboard: vm.session.clipboard,
                        onDisconnect: vm.disconnect)
        } else {
            ConnectView(vm: vm)
        }
    }
}