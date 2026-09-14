//
//  ConnectionFormView.swift
//  RDPClient
//
//  新建 / 编辑主机连接表单。
//

import SwiftUI

struct ConnectionFormView: View {
    /// 传入即为编辑模式
    var editing: RDPHost?

    @EnvironmentObject private var store: HostStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var portText = "3389"
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("主机") {
                    TextField("显示名称（可选）", text: $name)
                    TextField("IP 或主机名", text: $host)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $portText)
                        .keyboardType(.numberPad)
                }

                Section("Windows 凭据") {
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                    TextField("域（可选）", text: $domain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    HStack {
                        TextField("宽", text: $widthText)
                            .keyboardType(.numberPad)
                        Text("×")
                            .foregroundStyle(.secondary)
                        TextField("高", text: $heightText)
                            .keyboardType(.numberPad)
                    }
                } header: {
                    Text("远程桌面分辨率")
                } footer: {
                    Text("留空 = 自动按本机屏幕尺寸协商")
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle(editing == nil ? "新建连接" : "编辑连接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .onAppear(perform: loadEditing)
        }
    }

    private func loadEditing() {
        guard let editing else { return }
        name = editing.name
        host = editing.host
        portText = String(editing.port)
        username = editing.username
        domain = editing.domain
        if editing.desktopWidth > 0 {
            widthText = String(editing.desktopWidth)
            heightText = String(editing.desktopHeight)
        }
        // 密码不回显（Keychain 只写不读展示）；留空 = 保持原密码
    }

    private func save() {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty else {
            validationMessage = "请填写主机 IP 或主机名"
            return
        }
        guard let port = UInt16(portText), port > 0 else {
            validationMessage = "端口必须是 1–65535 的数字"
            return
        }
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMessage = "请填写 Windows 用户名"
            return
        }

        let width = UInt32(widthText) ?? 0
        let height = UInt32(heightText) ?? 0
        if width == 0 != (height == 0) {
            validationMessage = "分辨率需要同时填写宽和高，或都留空"
            return
        }

        var record = editing ?? RDPHost()
        record.name = name.trimmingCharacters(in: .whitespaces)
        record.host = trimmedHost
        record.port = port
        record.username = username.trimmingCharacters(in: .whitespaces)
        record.domain = domain.trimmingCharacters(in: .whitespaces)
        record.desktopWidth = width
        record.desktopHeight = height

        // 密码：编辑模式且留空 = 保持原值
        if !(editing != nil && password.isEmpty) {
            guard !password.isEmpty else {
                validationMessage = "请填写密码"
                return
            }
            do {
                try KeychainService.shared.savePassword(account: record.passwordRef.uuidString,
                                                        password: password)
            } catch {
                validationMessage = (error as? LocalizedError)?.errorDescription ?? "保存密码失败"
                return
            }
        }

        store.upsert(record)
        dismiss()
    }
}
