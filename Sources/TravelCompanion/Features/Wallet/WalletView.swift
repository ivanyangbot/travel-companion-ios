import SwiftData
import SwiftUI
import UIKit

/// 可嵌入的卡包内容（不含 NavigationStack），由「支出」页通过顶部切换承载。
struct WalletSection: View {
    @ObservedObject var syncEngine: SyncEngine
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LocalWalletItem.updatedAt, order: .reverse) private var items: [LocalWalletItem]
    @AppStorage("wallet.hasAcknowledgedPasteboardWarning") private var hasAcknowledgedPasteboardWarning = false

    @State private var decryptedSecrets: [UUID: WalletSecret] = [:]
    @State private var unreadableItemIDs = Set<UUID>()
    @State private var editor: WalletEditorTarget?
    @State private var pendingDeletion: LocalWalletItem?
    @State private var pendingCopy: WalletSecret?
    @State private var copied = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("本机卡包").font(.title3.bold())
                Spacer()
                Button("添加卡片", systemImage: "plus") { editor = .new }
                    .buttonStyle(.glass)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if items.isEmpty {
                ContentUnavailableView(
                    "还没有卡包",
                    systemImage: "wallet.pass",
                    description: Text("保存护照号、会员号等旅行常用号码；它们不会上传或同步。")
                )
                .padding(.top, 48)
                .frame(maxWidth: .infinity)
            } else {
                List {
                    if !unreadableItemIDs.isEmpty { recoveryNotice }
                    ForEach(items) { item in
                        walletRow(item)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(item: $editor) { target in
            WalletEditorView(syncEngine: syncEngine, item: target.item, existingSecret: target.item.flatMap { decryptedSecrets[$0.id] }) {
                loadSecrets()
            }
        }
        .alert("删除这张卡片？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("删除", role: .destructive) { deletePendingItem() }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("删除后只能重新手动添加，无法恢复。")
        }
        .alert("复制敏感号码？", isPresented: Binding(get: { pendingCopy != nil && !hasAcknowledgedPasteboardWarning }, set: { if !$0, !hasAcknowledgedPasteboardWarning { pendingCopy = nil } })) {
            Button("复制") {
                hasAcknowledgedPasteboardWarning = true
                copyPendingValue()
            }
            Button("取消", role: .cancel) { pendingCopy = nil }
        } message: {
            Text("剪贴板可能被其他 App 读取。请只粘贴到可信应用。")
        }
        .alert("已复制", isPresented: $copied) {
            Button("好", role: .cancel) { copied = false }
        } message: {
            Text("号码已复制到剪贴板。")
        }
        .alert("本机卡包", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task(id: items.map(\.id)) { loadSecrets() }
        .onDisappear {
            // Never retain a decrypted value after the section leaves view.
            decryptedSecrets = [:]
        }
    }

    @ViewBuilder
    private func walletRow(_ item: LocalWalletItem) -> some View {
        if let secret = decryptedSecrets[item.id] {
            WalletItemRow(
                item: item,
                secret: secret,
                onCopy: { requestCopy(secret) },
                onEdit: { editor = .edit(item) },
                onDelete: { pendingDeletion = item }
            )
        } else if unreadableItemIDs.contains(item.id) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.label).font(.headline)
                Label("无法在此设备上读取", systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        } else {
            HStack {
                Text(item.label)
                Spacer()
                ProgressView()
            }
        }
    }

    private var recoveryNotice: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("部分卡包数据无法解密", systemImage: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(.red)
                Text("这通常发生在设备迁移或钥匙串被清除后。为保护隐私，数据不会上传或恢复；你可以安全地清除此设备上无法读取的项目。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("清除无法读取的项目", role: .destructive, action: clearUnreadableItems)
            }
        }
    }

    private func loadSecrets() {
        do {
            let key = try KeychainStore().walletKey()
            var loaded: [UUID: WalletSecret] = [:]
            var failed = Set<UUID>()
            for item in items {
                do {
                    loaded[item.id] = try WalletCrypto.decrypt(item.encryptedSecret, using: key)
                } catch {
                    failed.insert(item.id)
                }
            }
            decryptedSecrets = loaded
            unreadableItemIDs = failed
        } catch {
            decryptedSecrets = [:]
            unreadableItemIDs = Set(items.map(\.id))
        }
    }

    private func requestCopy(_ secret: WalletSecret) {
        pendingCopy = secret
        if hasAcknowledgedPasteboardWarning { copyPendingValue() }
    }

    private func copyPendingValue() {
        guard let pendingCopy else { return }
        UIPasteboard.general.string = pendingCopy.number
        self.pendingCopy = nil
        copied = true
    }

    private func deletePendingItem() {
        guard let pendingDeletion else { return }
        modelContext.delete(pendingDeletion)
        do {
            try modelContext.save()
            decryptedSecrets[pendingDeletion.id] = nil
            unreadableItemIDs.remove(pendingDeletion.id)
        } catch {
            errorMessage = "无法删除卡片：\(error.localizedDescription)"
        }
        self.pendingDeletion = nil
    }

    private func clearUnreadableItems() {
        for item in items where unreadableItemIDs.contains(item.id) {
            modelContext.delete(item)
        }
        do {
            try modelContext.save()
            unreadableItemIDs = []
        } catch {
            errorMessage = "无法清除项目：\(error.localizedDescription)"
        }
    }
}

private struct WalletItemRow: View {
    let item: LocalWalletItem
    let secret: WalletSecret
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var isRevealed = false
    @State private var revealTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            artworkThumbnail
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.label).font(.headline)
                    Spacer()
                    Menu {
                        Button("编辑", systemImage: "pencil", action: onEdit)
                        Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("\(item.label) 的更多操作")
                }
                Text(isRevealed ? secret.number : WalletMasker.masked(secret.number))
                    .font(.body.monospaced())
                    .textSelection(.disabled)
                if let note = secret.note, !note.isEmpty {
                    Text(note).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button(isRevealed ? "隐藏" : "显示", systemImage: isRevealed ? "eye.slash" : "eye") {
                        toggleReveal()
                    }
                    .buttonStyle(.glass)
                    Button("复制", systemImage: "doc.on.doc", action: onCopy)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 4)
        .onDisappear { revealTask?.cancel() }
    }

    @ViewBuilder
    private var artworkThumbnail: some View {
        if let data = secret.image, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 88, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(.separator), lineWidth: 0.5))
        } else {
            let type = secret.cardType.flatMap(WalletCardType.init(rawValue:)) ?? .other
            WalletCardArtwork(cardType: type, label: item.label, number: secret.number)
                .scaleEffect(0.27)
                .frame(width: 88, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func toggleReveal() {
        revealTask?.cancel()
        isRevealed.toggle()
        guard isRevealed else { return }
        revealTask = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            isRevealed = false
        }
    }
}

private enum WalletEditorTarget: Identifiable {
    case new
    case edit(LocalWalletItem)

    var id: UUID {
        switch self {
        case .new: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        case let .edit(item): item.id
        }
    }

    var item: LocalWalletItem? {
        if case let .edit(item) = self { return item }
        return nil
    }
}
