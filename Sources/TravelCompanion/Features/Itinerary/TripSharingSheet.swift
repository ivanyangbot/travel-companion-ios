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
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 10) {
                    if canInvite {
                        inviteButton
                    }

                    memberSectionHeader

                    if isLoading && members.isEmpty {
                        loadingCard
                    } else if members.isEmpty {
                        emptyCard
                    } else {
                        ForEach(orderedMembers) { member in
                            memberRow(member)
                        }
                    }

                    if let errorMessage, !members.isEmpty {
                        errorCard(errorMessage)
                    }

                    Text("共享成员可以共同编辑行程、支出和手书内容。")
                        .font(.caption)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
            .refreshable { await refreshMembers() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PrimaryTabPalette.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(28)
        .presentationBackground(PrimaryTabPalette.background)
        .presentationContentInteraction(.scrolls)
        .interactiveDismissDisabled(isCreatingInvite)
        .accessibilityAddTraits(.isModal)
        .task { await refreshMembers() }
        .sheet(isPresented: Binding(
            get: { activityURL != nil },
            set: { if !$0 { activityURL = nil } }
        )) {
            if let activityURL {
                SystemActivityView(activityItems: [activityURL])
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("共享旅程")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text("管理同行成员与邀请")
                    .font(.caption)
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
            }

            Spacer(minLength: 0)

            Button(action: loadMembers) {
                Group {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 34, height: 34)
                .background(PrimaryTabPalette.elevatedSurface, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityLabel("刷新共享成员")

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(PrimaryTabPalette.elevatedSurface, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isCreatingInvite)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 18)
    }

    private var inviteButton: some View {
        Button(action: createInvite) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.18))
                    if isCreatingInvite {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text("邀请同行人")
                        .font(.body.weight(.bold))
                    Text("创建链接，通过系统分享给同行人")
                        .font(.caption)
                        .opacity(0.78)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(14)
            .background(
                PrimaryTabPalette.accent,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isCreatingInvite)
        .accessibilityHint("创建旅程邀请链接并打开系统分享")
    }

    private var memberSectionHeader: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 1)
            Text("同行成员 · \(members.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PrimaryTabPalette.secondaryText)
                .fixedSize()
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(PrimaryTabPalette.accent)
            Text("正在读取共享成员…")
                .foregroundStyle(PrimaryTabPalette.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(PrimaryTabPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2.slash")
                .font(.title2)
                .foregroundStyle(PrimaryTabPalette.accent)
            Text("暂时无法显示成员")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
            Text(errorMessage ?? "请稍后刷新重试。")
                .font(.caption)
                .foregroundStyle(PrimaryTabPalette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 116)
        .padding(.horizontal, 20)
        .background(PrimaryTabPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var orderedMembers: [TripMemberSummary] {
        members.sorted {
            if $0.isOwner != $1.isOwner { return $0.isOwner }
            return $0.joinedAt < $1.joinedAt
        }
    }

    private func memberRow(_ member: TripMemberSummary) -> some View {
        HStack(spacing: 14) {
            Image(systemName: member.isOwner ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(member.isOwner ? PrimaryTabPalette.accent : .white.opacity(0.72))
                .frame(width: 38, height: 38)
                .background(PrimaryTabPalette.elevatedSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(member.visibleName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let email = member.email,
                   !email.isEmpty,
                   email != member.visibleName {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(member.isOwner ? "创建者" : "共同编辑")
                .font(.caption.weight(.semibold))
                .foregroundStyle(member.isOwner ? PrimaryTabPalette.accent : PrimaryTabPalette.secondaryText)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 64)
        .background(PrimaryTabPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func errorCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(PrimaryTabPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
