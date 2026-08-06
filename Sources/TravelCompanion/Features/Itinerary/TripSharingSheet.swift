import SwiftUI
import UIKit

/// Member-centric sharing UI. Opening the share action always shows who
/// already has access; owners can then create an HTTPS invite and present the
/// native system share sheet from the same screen.
struct TripSharingSheet: View {
    @ObservedObject var syncEngine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var members: [TripMemberSummary] = []
    @State private var isLoading = true
    @State private var isCreatingInvite = false
    @State private var errorMessage: String?
    @State private var activityURL: URL?

    private var canInvite: Bool {
        syncEngine.trips.first(where: { $0.id == syncEngine.selectedTripID })?.canShare == true
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if isLoading && members.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在读取共享成员…")
                                .foregroundStyle(.secondary)
                        }
                    } else if members.isEmpty {
                        ContentUnavailableView(
                            "暂时无法显示成员",
                            systemImage: "person.2.slash",
                            description: Text(errorMessage ?? "请稍后下拉刷新。")
                        )
                    } else {
                        ForEach(orderedMembers) { member in
                            memberRow(member)
                        }
                    }
                } header: {
                    Text("已共享给（\(members.count)）")
                } footer: {
                    Text("共享成员可以共同编辑行程、支出和手书内容。")
                }

                if canInvite {
                    Section {
                        Button {
                            createInvite()
                        } label: {
                            HStack {
                                Label("邀请同行人", systemImage: "person.badge.plus")
                                Spacer()
                                if isCreatingInvite { ProgressView() }
                            }
                        }
                        .disabled(isCreatingInvite)
                    } footer: {
                        Text("将分享一个 HTTPS 链接。对方打开网页后会自动唤起 App；未安装时会前往 App Store。")
                    }
                }

                if let errorMessage, !members.isEmpty {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("共享旅程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("刷新", systemImage: "arrow.clockwise") { loadMembers() }
                        .disabled(isLoading)
                }
            }
            .refreshable { await refreshMembers() }
            .task { await refreshMembers() }
            .sheet(isPresented: Binding(
                get: { activityURL != nil },
                set: { if !$0 { activityURL = nil } }
            )) {
                if let activityURL {
                    SystemActivityView(activityItems: [activityURL])
                        .presentationDetents([.medium, .large])
                }
            }
        }
    }

    private var orderedMembers: [TripMemberSummary] {
        members.sorted {
            if $0.isOwner != $1.isOwner { return $0.isOwner }
            return $0.joinedAt < $1.joinedAt
        }
    }

    private func memberRow(_ member: TripMemberSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: member.isOwner ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle.fill")
                .font(.title2)
                .foregroundStyle(member.isOwner ? .indigo : .secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(member.visibleName)
                    .font(.body.weight(.semibold))
                if let email = member.email,
                   !email.isEmpty,
                   email != member.visibleName {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(member.isOwner ? "创建者" : "共同编辑")
                .font(.caption.weight(.semibold))
                .foregroundStyle(member.isOwner ? .indigo : .secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func loadMembers() {
        Task { await refreshMembers() }
    }

    private func refreshMembers() async {
        isLoading = true
        defer { isLoading = false }
        do {
            members = try await syncEngine.fetchTripMembers()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createInvite() {
        guard !isCreatingInvite else { return }
        isCreatingInvite = true
        errorMessage = nil
        Task {
            let url = await syncEngine.createShareInvite()
            isCreatingInvite = false
            if let url {
                activityURL = url
            } else {
                errorMessage = "当前旅程暂时无法创建邀请链接。"
            }
        }
    }
}

private struct SystemActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
