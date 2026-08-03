import SwiftUI

struct APISettingsView: View {
    let initialURL: String
    let onSave: (String) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var urlText: String
    @State private var validationMessage: String?

    init(initialURL: String, onSave: @escaping (String) -> String?) {
        self.initialURL = initialURL
        self.onSave = onSave
        _urlText = State(initialValue: initialURL)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("共享 API") {
                    TextField("https://api.example.com", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    Text("地址仅保存在本机。公开 API 没有登录保护，请勿把卡包或其他敏感信息发送到服务器。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let validationMessage {
                        Text(validationMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("连接设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let message = onSave(urlText) {
                            validationMessage = message
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
