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

    init() {
        CameraManager.purgeStaleTakes()
    }

    var body: some Scene {
        WindowGroup {
            ScriptListView()
                .environmentObject(store)
        }
    }
}
