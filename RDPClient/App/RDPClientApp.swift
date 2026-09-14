//
//  RDPClientApp.swift
//  RDPClient
//

import SwiftUI

@main
struct RDPClientApp: App {
    @StateObject private var store = HostStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
