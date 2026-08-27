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
                VStack(alignment: .leading, spacing: 2) {
                    Text("wallet.title")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("wallet.subtitle")
                        .font(.caption)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                }
                Spacer()
                Button { editor = .new } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(
                            PrimaryTabPalette.elevatedSurface,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("wallet.addA11y"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)

            if items.isEmpty {
                ContentUnavailableView(
                    "wallet.emptyTitle",
                    systemImage: "wallet.pass",
                    description: Text("wallet.emptyDesc")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 112)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if !unreadableItemIDs.isEmpty {
                            recoveryNotice
                        }
                        ForEach(items) { item in
                            walletRow(item)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 128)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(PrimaryTabPalette.background)
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(item: $editor) { target in
            WalletEditorView(syncEngine: syncEngine, item: target.item, existingSecret: target.item.flatMap { decryptedSecrets[$0.id] }) {
                loadSecrets()
            }
        }
        .alert("wallet.deleteTitle", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("common.delete", role: .destructive) { deletePendingItem() }
            Button("common.cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("wallet.deleteMessage")
        }
        .alert("wallet.copySensitiveTitle", isPresented: Binding(get: { pendingCopy != nil && !hasAcknowledgedPasteboardWarning }, set: { if !$0, !hasAcknowledgedPasteboardWarning { pendingCopy = nil } })) {
            Button("wallet.copyButton") {
                hasAcknowledgedPasteboardWarning = true
                copyPendingValue()
            }
            Button("common.cancel", role: .cancel) { pendingCopy = nil }
        } message: {
            Text("wallet.copySensitiveMessage")
        }
        .alert("wallet.copiedTitle", isPresented: $copied) {
            Button("common.ok", role: .cancel) { copied = false }
        } message: {
            Text("wallet.copiedMessage")
        }
        .alert("wallet.errorTitle", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("common.ok", role: .cancel) { errorMessage = nil }
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
            .padding(14)
            .primaryTabCardStyle(color: PrimaryTabPalette.elevatedSurface, cornerRadius: 15)
        } else if unreadableItemIDs.contains(item.id) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.label).font(.headline)
                Label("wallet.unreadable", systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .primaryTabCardStyle(color: PrimaryTabPalette.elevatedSurface, cornerRadius: 15)
        } else {
            HStack {
                Text(item.label)
                Spacer()
                ProgressView()
            }
            .padding(14)
            .primaryTabCardStyle(color: PrimaryTabPalette.elevatedSurface, cornerRadius: 15)
        }
    }

    private var recoveryNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("wallet.decryptIssueTitle", systemImage: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(.red)
            Text("wallet.decryptIssueDesc")
                .font(.footnote)
                .foregroundStyle(PrimaryTabPalette.secondaryText)
            Button("wallet.clearUnreadable", role: .destructive, action: clearUnreadableItems)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .primaryTabCardStyle(color: PrimaryTabPalette.surface, cornerRadius: 15)
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
            errorMessage = String(format: String(localized: "wallet.deleteFailed"), error.localizedDescription)
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
            errorMessage = String(format: String(localized: "wallet.clearFailed"), error.localizedDescription)
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
                    Text(item.label)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Menu {
                        Button("common.edit", systemImage: "pencil", action: onEdit)
                        Button("common.delete", systemImage: "trash", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.white.opacity(0.82))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(Text(String(format: String(localized: "common.moreActions"), item.label)))
                }
                Text(isRevealed ? secret.number : WalletMasker.masked(secret.number))
                    .font(.body.monospaced())
                    .foregroundStyle(.white.opacity(0.82))
                    .textSelection(.disabled)
                if let note = secret.note, !note.isEmpty {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                }
                HStack(spacing: 12) {
                    Button(isRevealed ? "wallet.hide" : "wallet.show", systemImage: isRevealed ? "eye.slash" : "eye") {
                        toggleReveal()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(PrimaryTabPalette.surface, in: Capsule())
                    .buttonStyle(.plain)
                    Button("wallet.copyButton", systemImage: "doc.on.doc", action: onCopy)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(.white, in: Capsule())
                        .buttonStyle(.plain)
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
