//
//  InTeleprompterApp.swift
//  InTeleprompter
//
//  Created by Jack Arnold on 6/11/26.
//

import SwiftUI

@main
struct InTeleprompterApp: App {
    @StateObject private var store = ScriptStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CameraManager.purgeStaleTakes()
    }

    var body: some Scene {
        WindowGroup {
            ScriptListView()
                .environmentObject(store)
                // Pick up whatever the share extension staged, whether the
                // app was already running or was just opened via its scheme.
                .onOpenURL { _ in store.importPendingSharedScripts() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.importPendingSharedScripts() }
                }
        }
    }
}
