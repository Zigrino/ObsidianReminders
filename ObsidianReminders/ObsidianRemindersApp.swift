//
//  ObsidianRemindersApp.swift
//  ObsidianReminders
//
//  Created by Yulian Itskov-Curto on 5/25/26.
//

import AppKit
import SwiftUI

@main
struct ObsidianRemindersApp: App {
    @StateObject private var syncViewModel = SyncViewModel()

    var body: some Scene {
        Window("ObsidianReminders", id: MainWindow.id) {
            ContentView(viewModel: syncViewModel)
        }
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            StatusMenu(viewModel: syncViewModel)
        } label: {
            Image(systemName: syncViewModel.isWorking ? "arrow.triangle.2.circlepath" : "bell.badge")
        }
    }
}

private enum MainWindow {
    static let id = "main"
}

private struct StatusMenu: View {
    @ObservedObject var viewModel: SyncViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openMainWindow()
        } label: {
            Label("Open Window", systemImage: "macwindow")
        }
        .keyboardShortcut("o", modifiers: .command)

        Button {
            Task {
                await viewModel.syncNow()
            }
        } label: {
            Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!viewModel.canSync)
        .keyboardShortcut("s", modifiers: .command)

        Toggle(isOn: $viewModel.isContinuousSyncEnabled) {
            Label("Auto Sync", systemImage: "clock.arrow.2.circlepath")
        }

        Divider()

        Label(viewModel.continuousSyncStatus, systemImage: viewModel.isContinuousSyncEnabled ? "clock" : "pause.circle")

        Text(Self.menuText(viewModel.statusMessage))
            .foregroundStyle(.secondary)

        Divider()

        Button {
            NSApp.terminate(nil)
        } label: {
            Label("Quit", systemImage: "power")
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private func openMainWindow() {
        openWindow(id: MainWindow.id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func menuText(_ text: String) -> String {
        let maxLength = 30
        guard text.count > maxLength else { return text }
        return "\(text.prefix(maxLength - 3))..."
    }
}
