//
//  ObsidianRemindersApp.swift
//  ObsidianReminders
//
//  Created by Yulian Itskov-Curto on 5/25/26.
//

import SwiftUI

@main
struct ObsidianRemindersApp: App {
    @StateObject private var syncViewModel = SyncViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: syncViewModel)
        }
    }
}
