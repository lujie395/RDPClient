//
//  HostListView.swift
//  RDPClient
//
//  主机列表：点击连接，侧滑编辑 / 删除。
//

import SwiftUI

struct HostListView: View {
    @EnvironmentObject private var store: HostStore

    @State private var showNewForm = false
    @State private var editingHost: RDPHost?
    @State private var connectingHost: RDPHost?

    var body: some View {
        NavigationStack {
            Group {
                if store.hosts.isEmpty {
                    // iOS 16 兼容写法（ContentUnavailableView 需要 iOS 17+）
                    VStack(spacing: 12) {
                        Image(systemName: "display.and.arrow.down")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("还没有连接")
                            .font(.title3.weight(.medium))
                        Text("点击右上角 +，添加局域网里的 Windows 电脑")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.hosts) { host in
                            row(host)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                store.remove(id: store.hosts[index].id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("RDP 连接")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNewForm = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showNewForm) {
                ConnectionFormView()
                    .environmentObject(store)
            }
            .sheet(item: $editingHost) { host in
                ConnectionFormView(editing: host)
                    .environmentObject(store)
            }
            // iOS 16 兼容：navigationDestination(item:) 需要 iOS 17+，
            // 改用 isPresented 形式
            .navigationDestination(isPresented: Binding(
                get: { connectingHost != nil },
                set: { if !$0 { connectingHost = nil }
                })) {
                if let host = connectingHost {
                    RemoteScreenView(host: host)
                        .environmentObject(store)
                }
            }
        }
    }

    private func row(_ host: RDPHost) -> some View {
        Button {
            connectingHost = host
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(host.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(host.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let last = host.lastConnectedAt {
                    Text("上次连接：" + last.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button("编辑") {
                editingHost = host
            }
            .tint(.blue)
            Button("删除", role: .destructive) {
                store.remove(id: host.id)
            }
        }
    }
}
