import PhotosUI
import SwiftUI
import UIKit

/// The PRD's local-first planning workbench. Drafts remain local until the
/// user explicitly selects and commits candidate cards.
struct AgentWorkbenchView: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var appleSignIn: AppleSignInStore
    let initialMessage: String?
    let onInitialMessageSubmitted: (() -> Void)?
    @EnvironmentObject private var store: AgentV2SessionStore
    @EnvironmentObject private var runState: AgentV2RunState
    @FocusState private var isComposerFocused: Bool
    @State private var message = ""
    @State private var photo: PhotosPickerItem?
    @State private var isShowingContext = false
    @State private var isShowingHistory = false
    @State private var didConsumeInitialMessage = false
    @State private var didSubmitInitialMessage = false
    @State private var streamingScrollTask: Task<Void, Never>?
    @State private var isCreatingTripFromProposal = false
    @State private var isReasoningExpanded = false
    @State private var suggestedPrompts: [String] = []
    @State private var suggestedIcons: [String] = []
    @State private var suggestionsTripID: Int?

    init(
        syncEngine: SyncEngine,
        appleSignIn: AppleSignInStore,
        initialMessage: String? = nil,
        onInitialMessageSubmitted: (() -> Void)? = nil
    ) {
        self.syncEngine = syncEngine
        self.appleSignIn = appleSignIn
        self.initialMessage = initialMessage
        self.onInitialMessageSubmitted = onInitialMessageSubmitted
    }

    var body: some View {
        AgentHomeView(
            syncEngine: syncEngine,
            appleSignIn: appleSignIn,
            initialMessage: initialMessage,
            onInitialMessageSubmitted: onInitialMessageSubmitted,
            presentation: .workbench
        )
    }

    /// 与各主页面一致的暗色自定义头部：居中标题、左侧行程切换（Liquid Glass 菜单）、右侧历史与新建对话。
    private var agentHeader: some View {
        ZStack {
            Text("旅行 Agent")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            HStack(spacing: 12) {
                // 行程切换：可以「暂不选择行程」，仅影响 Agent 的上下文，不修改任何行程数据。
                Menu {
                    Button {
                        Task { await syncEngine.clearSelectedTrip() }
                    } label: {
                        if syncEngine.selectedTripID == nil {
                            Label("暂不选择行程", systemImage: "checkmark")
                        } else {
                            Text("暂不选择行程")
                        }
                    }
                    if !syncEngine.trips.isEmpty {
                        Divider()
                        ForEach(syncEngine.trips) { summary in
                            Button {
                                // 切换行程即自动开启新对话：当前对话有内容时归档到
                                // 「历史」（空会话不产生归档）；旧行程的建议立即清掉，
                                // 新行程的建议由 trip 变更回调重新拉取。
                                guard summary.id != syncEngine.selectedTripID else { return }
                                startNewConversation()
                                suggestedPrompts = []
                                suggestedIcons = []
                                Task { await syncEngine.selectTrip(summary.id) }
                            } label: {
                                if summary.id == syncEngine.selectedTripID {
                                    Label(summary.displayName, systemImage: "checkmark")
                                } else {
                                    Text(summary.displayName)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PrimaryTabPalette.accent)
                        Text(tripTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                    }
                }
                .buttonStyle(.glass)
                .frame(maxWidth: 170, alignment: .leading)
                .accessibilityLabel("切换行程")
                .accessibilityHint("选择要规划的行程，或打开旅行与偏好设置")

                Spacer(minLength: 0)

                Button { isShowingHistory = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("历史对话")

                Button { startNewConversation() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.glass)
                .disabled(isWelcomeState)
                .accessibilityLabel("新建对话")
            }
        }
        .frame(height: 48)
        .padding(.horizontal, 20)
        .padding(.top, 2)
        // .overlay(alignment: .bottom) {
        //     Rectangle().fill(PrimaryTabPalette.divider).frame(height: 1)
        // }
    }

    private var tripTitle: String {
        guard let trip = syncEngine.trip, trip.isConfigured else { return "未设置旅行" }
        return trip.destination ?? "本次旅行"
    }

    private var isWelcomeState: Bool {
        store.session.messages.isEmpty && store.session.draft == nil
    }

    private var welcomeView: some View {
        VStack(alignment: .leading, spacing: 24) {
ZStack {
// 与地球同心的圆形橙色光晕，位于下层：字符叠在光晕之上，不会被糊住。
Circle()
.fill(
RadialGradient(
colors: [PrimaryTabPalette.accent.opacity(0.5), PrimaryTabPalette.accent.opacity(0)],
center: .center,
startRadius: 30,
endRadius: 130
)
)
.frame(width: 260, height: 260)
.blur(radius: 24)
.allowsHitTesting(false)
AgentIntroGlobeView(diameter: 208)
}
        .frame(maxWidth: .infinity)
        .padding(.top, 12)

            VStack(alignment: .leading, spacing: 12) {
                Text("告诉豆奶你想去哪里。")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
            }

            tripContextCard

            if !displayedPrompts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("可以这样问")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                    ForEach(Array(displayedPrompts.enumerated()), id: \.element) { index, prompt in
                        Button { usePrompt(prompt) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: suggestionIcon(at: index, fallback: prompt))
                                    .frame(width: 24)
                                    .foregroundStyle(PrimaryTabPalette.accent)
                                Text(prompt)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(PrimaryTabPalette.tertiaryText)
                            }
                            .padding(15)
                            .primaryTabCardStyle(color: PrimaryTabPalette.surface, cornerRadius: 18)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .offset(y: 10)))
                        // 动态建议返回时逐条渐入（80ms 阶梯延迟）
                        .animation(.easeOut(duration: 0.35).delay(Double(index) * 0.08), value: displayedPrompts)
                    }
                }
            }
        }
    }

    private var tripContextCard: some View {
        Button { isShowingContext = true } label: {
            HStack(spacing: 12) {
                Image(systemName: syncEngine.trip?.isConfigured == true ? "map.fill" : "calendar.badge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(PrimaryTabPalette.accent)
                    .frame(width: 36, height: 36)
                    .background(PrimaryTabPalette.accent.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(tripTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text(tripContextSubtitle).font(.caption).foregroundStyle(PrimaryTabPalette.secondaryText).lineLimit(2)
                }
                Spacer()
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
            }
            .padding(14)
            .primaryTabCardStyle(color: PrimaryTabPalette.surface, cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }

    private var tripContextSubtitle: String {
        guard let trip = syncEngine.trip, trip.isConfigured else { return "先设置目的地、日期，再开始规划" }
        var details = ["\(trip.startDate ?? "") – \(trip.endDate ?? "")"]
        let preferences = preferenceLabels
        if !preferences.isEmpty { details.append(preferences.joined(separator: " · ")) }
        return details.joined(separator: "  ·  ")
    }

    private var preferenceLabels: [String] {
        let preferences = store.session.preferences
        return [
            preferenceTitle(preferences.pace, values: ["relaxed": "轻松", "balanced": "均衡", "packed": "特种兵"]),
            preferenceTitle(preferences.companions, values: ["solo": "独自", "couple": "情侣", "parents": "带父母", "children": "带儿童"]),
            preferenceTitle(preferences.budget, values: ["value": "省钱", "balanced": "适中", "premium": "品质优先"])
        ].compactMap { $0 }
    }

    private func preferenceTitle(_ value: String?, values: [String: String]) -> String? {
        guard let value else { return nil }
        return values[value]
    }

    private var conversationView: some View {
        VStack(alignment: .leading, spacing: 22) {
            // 橘色头像每个助手回合只显示一次（该回合第一条消息）；其余
            // 助手区块保留同样的缩进对齐，但不再重复头像。
            ForEach(Array(store.session.messages.enumerated()), id: \.element.id) { index, item in
                ChatMessageView(
                    message: item,
                    showsAvatar: item.role == "user" || index == 0 || store.session.messages[index - 1].role == "user"
                )
            }

            // 思考摘要只在本轮生成期间可见，且始终位于当轮回复上方。
            // 状态行本身承载展开/收起（箭头也在这一行）：有摘要时点按
            // 状态行切换，摘要就地展开在状态行下方、回复上方。
            if let status = runState.status {
                // 状态行不使用 AssistantMessageContainer：头像占位会让 orb
                // 右移，这一行需要顶着左边缘显示（orb 本身就是行首图标）。
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isReasoningExpanded.toggle() }
                    } label: {
                        HStack(spacing: 10) {
                            ThinkingOrb(state: agentThinkingOrbState(for: status), size: .px20, theme: .dark)
                            // 思考状态限定单行，过长时尾部省略，避免状态行被长文案撑高。
                            Text(status)
                                .lineLimit(1)
                                .foregroundStyle(PrimaryTabPalette.secondaryText)
                            Spacer(minLength: 8)
                            if !runState.reasoningSummary.isEmpty {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(PrimaryTabPalette.tertiaryText)
                                    .rotationEffect(.degrees(isReasoningExpanded ? 90 : 0))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(runState.reasoningSummary.isEmpty)

                    if isReasoningExpanded, !runState.reasoningSummary.isEmpty {
                        Text(runState.reasoningSummary)
                            .font(.footnote)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if runState.isGenerating, !runState.reasoningSummary.isEmpty {
                // 回复开始流出后状态行消失，此时直接把摘要内容展示在回复上方。
                AssistantMessageContainer(showsAvatar: false) {
                    Text(runState.reasoningSummary)
                        .font(.footnote)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !runState.streamingReply.isEmpty {
                AssistantMessageContainer(showsAvatar: false) {
                    Text(runState.streamingReply)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityHidden(true)
            }

            if let fliggy = runState.fliggyProgress {
                AssistantMessageContainer(showsAvatar: false) {
                    FliggySearchStatusChip(progress: fliggy)
                }
            }

            if !runState.liveCards.isEmpty {
                AssistantMessageContainer(showsAvatar: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("正在生成候选")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        ForEach(runState.liveCards) { card in
                            LiveCandidateCard(card: card)
                        }
                    }
                }
            }

            if let proposal = store.session.pendingProposal, syncEngine.trip?.isConfigured != true {
                AssistantMessageContainer(showsAvatar: false) {
                    tripProposalCard(proposal)
                }
            }

            if store.session.summary != nil || store.session.draft != nil {
                AssistantMessageContainer(showsAvatar: false) {
                    workbenchView
                }
            }
        }
    }

    @ViewBuilder private var workbenchView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let summary = store.session.summary {
                VStack(alignment: .leading, spacing: 8) {
                    Label("本轮建议", systemImage: "sparkles")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(summary.text)
                        .foregroundStyle(.white.opacity(0.85))
                    if !summary.pending.isEmpty {
                        Label(summary.pending.joined(separator: "、"), systemImage: "questionmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let draft = store.session.draft {
                if !draft.candidates.isEmpty {
                    // 草稿随对话跨轮延续：区分本轮新产出与前几轮未确认的候选，
                    // 避免列表越滚越长时用户分不清来源。旧版本会话没有
                    // lastTurnCandidateIDs 时全部视为本轮。
                    let lastTurnIDs = Set(store.session.lastTurnCandidateIDs ?? draft.candidates.map(\.id))
                    let current = draft.candidates.filter { lastTurnIDs.contains($0.id) }
                    let carried = draft.candidates.filter { !lastTurnIDs.contains($0.id) }
                    VStack(alignment: .leading, spacing: 10) {
                        if !current.isEmpty {
                            candidateGroup(title: carried.isEmpty ? "候选行程" : "本轮新增（\(current.count)）", candidates: current)
                        }
                        if !carried.isEmpty {
                            candidateGroup(title: "前几轮待确认（\(carried.count)）", candidates: carried)
                        }
                    }
                }

                if !draft.changes.isEmpty {
                    DisclosureGroup("查看变更清单（\(draft.changes.count)）") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(draft.changes) { change in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: change.operation.symbol)
                                        .foregroundStyle(change.operation.tint)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(change.operationTitle + " · " + change.summary)
                                            .font(.subheadline)
                                            .foregroundStyle(.white)
                                        if let impact = change.impact {
                                            Text(impact).font(.caption).foregroundStyle(PrimaryTabPalette.secondaryText)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 10)
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(PrimaryTabPalette.secondaryText)
                }

                let selected = draft.candidates.filter(\.selected)
                let commitReady = draft.candidates.filter(\.isCommitReady)
                let allCommitReadySelected = !commitReady.isEmpty && commitReady.allSatisfy(\.selected)
                // 变更清单中待确认的“移除行程卡”提案：无选中候选时也可单独提交。
                let pendingRemovals = draft.changes.filter { $0.operation == .remove && $0.targetCardId != nil }
                let hasBlockingSelection = selected.contains(where: { !$0.isCommitReady })
                let canCommit = !runState.isCommitting && !hasBlockingSelection && (!selected.isEmpty || !pendingRemovals.isEmpty)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("可导入 \(commitReady.count) 项" + (pendingRemovals.isEmpty ? "" : " · 待移除 \(pendingRemovals.count) 项"))
                            .font(.caption)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                        Spacer()
                        Button(allCommitReadySelected ? "取消全选" : "全选可导入项") {
                            store.setSelected(!allCommitReadySelected, ids: Set(commitReady.map(\.id)))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PrimaryTabPalette.accent)
                        .disabled(commitReady.isEmpty || runState.isCommitting)
                    }

                    Button { commit() } label: {
                        HStack {
                            if runState.isCommitting { ProgressView().tint(.white) }
                            Text(selected.isEmpty ? "确认移除（\(pendingRemovals.count)）" : "确认加入行程（\(selected.count)）")
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .background(PrimaryTabPalette.accent, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canCommit)
                    .opacity(canCommit || runState.isCommitting ? 1 : 0.45)

                    if hasBlockingSelection {
                        Text("仍在验证的地点暂不可加入；“地点待确认”的用户原文项目可以直接加入，稍后再补地图点位。")
                            .font(.caption)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                    } else if selected.isEmpty && !pendingRemovals.isEmpty {
                        Text("确认后只会从行程中移除变更清单里列出的卡片，其他内容不变。")
                            .font(.caption)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                    } else {
                        Text("确认前不会改动当前行程，未选择的候选仍留在本机草稿中。")
                            .font(.caption)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                    }
                }
            }
        }
        .padding(14)
        .primaryTabCardStyle(color: PrimaryTabPalette.surface, cornerRadius: 20)
    }

    /// plan_new 产出的旅程提案确认卡：仅在仍无生效旅程时展示。
    private func tripProposalCard(_ proposal: AgentV2TripProposal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("旅程提案", systemImage: "map")
                .font(.headline)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 6) {
                Label(proposal.destination, systemImage: "location.fill")
                Label("\(proposal.startDate) 至 \(proposal.endDate)", systemImage: "calendar")
                Label("币种 \(proposal.currency)", systemImage: "creditcard")
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.85))

            Button { confirmTripProposal(proposal) } label: {
                HStack {
                    if isCreatingTripFromProposal { ProgressView().tint(.white) }
                    Text("确认创建旅程")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 50)
                .background(PrimaryTabPalette.accent, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isCreatingTripFromProposal)
            .opacity(isCreatingTripFromProposal ? 0.7 : 1)

            Text("确认后才会创建旅程；候选仍需在下方选择后加入行程。")
                .font(.caption)
                .foregroundStyle(PrimaryTabPalette.secondaryText)
        }
        .padding(14)
        .primaryTabCardStyle(color: PrimaryTabPalette.surface, cornerRadius: 20)
    }

    @ViewBuilder
    private func candidateGroup(title: String, candidates: [AgentV2Candidate]) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PrimaryTabPalette.secondaryText)
        ForEach(candidates) { candidate in
            AgentV2CandidateCard(candidate: candidate) { value in
                store.setSelected(value, id: candidate.id)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !store.session.attachments.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundStyle(PrimaryTabPalette.accent)
                    Text("已附 \(store.session.attachments.count) 张图片")
                        .foregroundStyle(.white)
                    Text("· 发送失败后仍可重试").foregroundStyle(PrimaryTabPalette.secondaryText)
                    Spacer()
                }
                .font(.caption)
                .padding(.horizontal, 4)
            }

            // 「+」、输入框、发送键垂直居中对齐（多行输入时两侧按钮随行高中点）。
            HStack(alignment: .center, spacing: 8) {
                PhotosPicker(selection: $photo, matching: .images) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(PrimaryTabPalette.elevatedSurface, in: Circle())
                }
                .buttonStyle(.plain)
                .onChange(of: photo) { _, item in load(item) }
                .accessibilityLabel("添加攻略图片")

                TextField("告诉 Agent 你的想法", text: $message, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($isComposerFocused)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(PrimaryTabPalette.elevatedSurface, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .onSubmit { if canSend { send() } }

                Button { runState.isGenerating ? cancelGeneration() : send() } label: {
                    Image(systemName: runState.isGenerating ? "stop.fill" : "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(canSend || runState.isGenerating ? .white : PrimaryTabPalette.tertiaryText)
                        .frame(width: 36, height: 36)
                        .background(canSend || runState.isGenerating ? PrimaryTabPalette.accent : PrimaryTabPalette.elevatedSurface, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!runState.isGenerating && !canSend)
                .accessibilityLabel(runState.isGenerating ? "停止生成" : "发送")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(PrimaryTabPalette.background)
        .overlay(alignment: .top) {
            Rectangle().fill(PrimaryTabPalette.divider).frame(height: 1)
        }
    }

    private var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !runState.isGenerating
    }

    private func promptIcon(_ prompt: String) -> String {
        if prompt.contains("粘贴小红书") { return "link" }
        if prompt.contains("去小红书找") { return "magnifyingglass" }
        if prompt.contains("父母") { return "figure.2.and.child.holdinghands" }
        if prompt.contains("室内") { return "cloud.rain" }
if prompt.contains("500") { return "banknote" }
return "sparkles"
    }

private func usePrompt(_ prompt: String) {
message = prompt
isComposerFocused = true
}

    /// 欢迎页展示的提问：只使用服务端按当前行程（或整段旅程模式）生成的
    /// 三条建议；未返回前不显示本地静态提示，整个区块随结果渐入。
    private var displayedPrompts: [String] {
        suggestedPrompts
    }

/// 服务端返回的建议使用 AI 选择的图标；本地静态提示沿用关键词映射。
private func suggestionIcon(at index: Int, fallback prompt: String) -> String {
    guard !suggestedPrompts.isEmpty, index < suggestedIcons.count else { return promptIcon(prompt) }
    return suggestedIcons[index]
}

    /// 拉取三条动态建议（独立于 Agent 轮次管线的轻量接口）。有生效行程时
    /// 行程上下文与 Agent 轮次传入的同构；没有生效行程时以 journey 模式
    /// 请求整段旅程规划类建议。失败时静默回退，不占用错误弹窗。
    private func loadSuggestionsIfNeeded() {
        guard isWelcomeState else { return }
        let trip = syncEngine.trip
        let hasActiveTrip = trip?.isConfigured == true
        // -1 是“无生效行程”的请求键，与真实 trip id 区分。
        let suggestionKey = hasActiveTrip ? (trip?.id ?? -1) : -1
        guard suggestionsTripID != suggestionKey else { return }
        suggestionsTripID = suggestionKey
        let preferences = store.session.preferences
        let request = AITripSuggestionsRequest(
            mode: hasActiveTrip ? nil : "journey",
            destination: trip?.destination,
            startDate: trip?.startDate,
            endDate: trip?.endDate,
            currency: trip?.currency,
            preferences: AITripSuggestionsRequest.Preferences(
                pace: preferences.pace,
                companions: preferences.companions,
                budget: preferences.budget,
                scope: preferences.scope,
                interests: preferences.interests.isEmpty ? nil : preferences.interests
            ),
            existingItinerary: hasActiveTrip ? syncEngine.existingItinerarySnapshot() : nil
        )
        Task {
            guard let result = try? await APIClient().fetchTripSuggestions(request, tripID: hasActiveTrip ? trip?.id : nil),
                  !result.suggestions.isEmpty,
                  suggestionsTripID == suggestionKey else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                suggestedPrompts = result.suggestions
                suggestedIcons = result.icons ?? []
            }
        }
    }

    private func consumeInitialMessageIfNeeded() {
        guard !didConsumeInitialMessage,
              message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let initialMessage,
              !initialMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        didConsumeInitialMessage = true
        message = initialMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        isComposerFocused = true
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            } else {
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
        }
    }

    private func scheduleStreamingScroll(_ proxy: ScrollViewProxy) {
        guard streamingScrollTask == nil else { return }
        streamingScrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            proxy.scrollTo("conversation-bottom", anchor: .bottom)
            streamingScrollTask = nil
        }
    }

    private func clearSession() {
        store.discardTurn()
        runState.clearTransientState()
        store.clear()
    }

    /// 归档当前对话（可从「历史」恢复）并开启一个全新的本地会话。
    private func startNewConversation() {
        runState.clearTransientState()
        store.startNewSession()
    }

    private func cancelGeneration() {
        runState.cancelGeneration()
        store.discardTurn()
    }

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        // 服务端每轮最多接受 3 张附件；超出会在整轮校验时 400，提前拦截。
        guard store.session.attachments.count < 3 else {
            photo = nil
            runState.error = "每轮最多附带 3 张图片，请先清除对话与草稿后再添加。"
            return
        }
        Task {
            defer { photo = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw AgentImageAttachmentError.unreadable
                }
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try AgentImageAttachmentProcessor.prepare(data)
                }.value
                store.addAttachment(.init(
                    id: UUID(),
                    mediaType: prepared.mediaType,
                    dataURI: prepared.dataURI
                ))
            } catch {
                runState.error = error.localizedDescription
            }
        }
    }

    private func send() {
        guard let request = makeRequest() else { runState.error = "请先完成旅行设置。"; return }
        // plan_new（无生效旅程或「暂不选择行程」）时 tripID 为 nil，服务端不强制本接口的旅程鉴权。
        let tripID = syncEngine.trip?.id
        let userMessage = AgentV2TurnRequest.Message(id: UUID(), role: "user", content: message, createdAt: .now)
        store.beginTurn()
        store.append(userMessage)
        acknowledgeInitialMessageSubmissionIfNeeded(userMessage.content)
        message = ""
        runState.prepareForTurn()
        isComposerFocused = false
        let state = runState
        let sessionStore = store
        let client = APIClient()
        let generationID = runState.beginGeneration()
        let task = Task {
            do {
                let stream = try await client.agentV2Stream(request, tripID: tripID)
                for try await event in stream {
                    switch event {
                    case .status(let text): state.status = text
                    case .reasoningSummary(let text): state.reasoningSummary += text
                    case .assistantDelta(let text):
                        state.status = nil
                        state.appendStreamingReply(text)
                    case .cardBegin(let id, let index):
                        if !state.liveCards.contains(where: { $0.id == id }) { state.liveCards.append(.init(id: id, index: index)) }
                    case .cardFieldDelta(let id, let field, let value):
                        guard let index = state.liveCards.firstIndex(where: { $0.id == id }) else { break }
                        state.liveCards[index].fields[field] = value
                    case .question(let text): sessionStore.append(.init(id: UUID(), role: "assistant", content: text, createdAt: .now))
                    case .summary(let summary):
                        state.stagedSummaryText = summary.text
                        sessionStore.apply(event)
                    case .candidateUpsert:
                        sessionStore.apply(event)
                    case .fliggySearchStarted(let start):
                        state.fliggySearchStarted(start)
                    case .fliggySearchCompleted(let completion):
                        state.fliggySearchCompleted(completion)
                    case .done:
                        state.flushStreamingReply()
                        let completedReply = state.streamingReply.isEmpty ? state.stagedSummaryText : state.streamingReply
                        if !completedReply.isEmpty {
                            sessionStore.append(.init(id: UUID(), role: "assistant", content: completedReply, createdAt: .now))
                            state.streamingReply = ""
                        }
                        sessionStore.completeTurn()
                        state.liveCards = []
                    default: sessionStore.apply(event)
                    }
                }
            } catch is CancellationError {
                // The persisted draft, input context and attachments remain retryable.
            } catch {
                state.error = error.localizedDescription
            }
            sessionStore.discardTurn()
            state.liveCards = []
            state.stagedSummaryText = ""
            state.finishGeneration(id: generationID)
        }
        runState.attach(task, id: generationID)
    }

    private func acknowledgeInitialMessageSubmissionIfNeeded(_ submittedMessage: String) {
        guard !didSubmitInitialMessage,
              let initialURL = initialMessage?
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .first(where: { $0.hasPrefix("https://") }),
              submittedMessage.contains(initialURL) else { return }
        didSubmitInitialMessage = true
        onInitialMessageSubmitted?()
    }

    private func makeRequest() -> AgentV2TurnRequest? {
        guard let trip = syncEngine.trip, trip.isConfigured else {
            // 无生效旅程：从零规划模式（plan_new）。服务端会产出待用户确认的
            // 旅程提案（trip_proposal），确认前不落库创建旅程。
            return AgentV2TurnRequest(sessionId: store.session.id, turnId: UUID(), intent: "plan_new", message: message, trip: nil, preferences: store.session.preferences, history: AgentV2TurnRequest.trimmedHistory(store.session.messages), activeDraft: store.session.draft, attachments: store.session.attachments)
        }
        let days = trip.days.map { day in
            AgentV2TurnRequest.Day(date: day.date, cards: day.cards.map { card in
                AgentV2TurnRequest.Card(id: card.serverID, kind: card.kind.rawValue, title: card.title, startAt: ISO8601DateFormatter().string(from: card.startAt), endAt: card.endAt.map { ISO8601DateFormatter().string(from: $0) }, place: card.place?.name, notes: card.notes)
            })
        }
        return AgentV2TurnRequest(sessionId: store.session.id, turnId: UUID(), intent: "itinerary", message: message, trip: .init(destination: trip.destination, startDate: trip.startDate, endDate: trip.endDate, currency: trip.currency, timeZone: TimeZone.current.identifier, version: trip.version, days: days), preferences: store.session.preferences, history: AgentV2TurnRequest.trimmedHistory(store.session.messages), activeDraft: store.session.draft, attachments: store.session.attachments)
    }

    /// 用户确认旅程提案：复用既有建旅程链路创建旅程，随后清除提案。
    /// 候选不自动写入——创建成功后仍由用户在下方的草稿区选择并确认加入行程。
    private func confirmTripProposal(_ proposal: AgentV2TripProposal) {
        guard !isCreatingTripFromProposal else { return }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let startDate = formatter.date(from: proposal.startDate),
              let endDate = formatter.date(from: proposal.endDate) else {
            runState.error = "旅程提案的日期无法识别，请让 Agent 重新生成提案。"
            return
        }
        isCreatingTripFromProposal = true
        Task {
            await syncEngine.createTrip(destination: proposal.destination, startDate: startDate, endDate: endDate, currency: proposal.currency)
            if syncEngine.trip != nil {
                store.clearPendingProposal()
            } else {
                runState.error = "旅程创建失败，请稍后重试。"
            }
            isCreatingTripFromProposal = false
        }
    }

    private func commit() {
        guard let trip = syncEngine.trip else { return }
        // Obtain draft and selected IDs atomically from the current published
        // session. The button's `draft`/`selected` values belong to an earlier
        // SwiftUI render and can be stale after a streaming turn completes.
        guard let snapshot = store.commitSnapshot() else {
            runState.error = "当前没有可确认的候选，请重新选择后确认。"
            return
        }
        guard snapshot.selected.allSatisfy(\.isCommitReady) else {
            runState.error = "选中的候选仍在生成或缺少必要时间信息，请稍后再确认。"
            return
        }

        runState.isCommitting = true
        let client = APIClient()
        Task {
            do {
                _ = try await client.commitAgentV2(
                    .init(
                        sessionId: store.session.id,
                        expectedTripVersion: trip.version,
                        timeZone: TimeZone.current.identifier,
                        selectedCandidateIds: snapshot.selected.map(\.id),
                        draft: snapshot.draft
                    ),
                    tripID: trip.id,
                    idempotencyKey: UUID()
                )
                store.clearCommittedDraft()
                await syncEngine.refresh()
            } catch {
                runState.error = error.localizedDescription
            }
            runState.isCommitting = false
        }
    }
}

/// Maps an ephemeral agent status line to a ThinkingOrb state so each agent
/// behaviour gets its own icon. The status strings originate from the
/// backend's SSE `status` events (`app/routes/agent_v2.py`) plus the
/// client-side "正在理解你的需求…" seed; like the status text itself this is
/// pure UI progress and never persists. Keyword order matters: more specific
/// activities are matched before generic ones.
func agentThinkingOrbState(for status: String?) -> OrbState {
    guard let status else { return .breathing }
    // 理解用户输入（每轮开始时客户端播种）
    if status.contains("理解") { return .listening }
    // 并行验证候选地点 / 从笔记中识别可定位地点
    if status.contains("验证") || status.contains("识别") { return .solving }
    // 整理地点 / 挑选高质量笔记
    if status.contains("整理") || status.contains("挑选") { return .weaving }
    // Apple Maps 核对地点（先于"生成"匹配：初始状态为"联网核对攻略并生成建议"）
    if status.contains("核对") { return .searching }
    // 生成候选卡、整理候选结果
    if status.contains("生成") || status.contains("候选") { return .composing }
    // 读取小红书公开笔记、联网获取
    if status.contains("读取") || status.contains("联网") { return .connecting }
    // 豆包/小红书/飞猪搜索、实时价格查询
    if status.contains("搜索") || status.contains("查询") { return .searching }
    // 默认：模型推理中
    return .breathing
}

/// 历史对话列表：展示「新建对话」归档的本地会话，点按恢复、左滑删除。
/// 全部使用原生控件（List / swipeActions / ContentUnavailableView）。
private struct AgentHistorySheet: View {
    @ObservedObject var store: AgentV2SessionStore
    /// Called after a conversation is restored so the workbench can drop any
    /// in-flight generation UI for the previous conversation.
    let onRestore: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.archives.isEmpty {
                    ContentUnavailableView(
                        "暂无历史对话",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("点击「新建对话」后，当前对话会自动保存在这里。")
                    )
                } else {
                    List {
                        ForEach(store.archives) { archived in
                            Button {
                                store.restoreSession(id: archived.id)
                                onRestore()
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(title(for: archived))
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text(archived.updatedAt, style: .relative)
                                        Text("· \(archived.messages.count) 条消息")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    store.deleteArchivedSession(id: archived.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .accessibilityLabel("恢复对话：\(title(for: archived))")
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("历史对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// First user message as the conversation title, falling back to the
    /// assistant's opening or a placeholder.
    private func title(for session: AgentV2LocalSession) -> String {
        let text = session.messages.first(where: { $0.role == "user" })?.content
            ?? session.messages.first?.content
            ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名对话" : String(trimmed.prefix(40))
    }
}

private struct ChatMessageView: View {
    let message: AgentV2TurnRequest.Message
    /// 是否在这条助手消息旁显示橘色头像（每个助手回合只显示一次）。
    var showsAvatar: Bool = true

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 54)
                Text(message.content)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(PrimaryTabPalette.accent, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            }
        } else {
            AssistantMessageContainer(showsAvatar: showsAvatar) {
                Text(message.content)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct AssistantMessageContainer<Content: View>: View {
    @ViewBuilder let content: Content
    let showsAvatar: Bool

    init(showsAvatar: Bool = true, @ViewBuilder content: () -> Content) {
        self.showsAvatar = showsAvatar
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsAvatar {
                ZStack {
                    Circle().fill(PrimaryTabPalette.accent.gradient).frame(width: 28, height: 28)
                    Image(systemName: "sparkles").font(.caption2.weight(.bold)).foregroundStyle(.white)
                }
            } else {
                // 占位对齐：不显示头像时内容仍与其他助手区块左对齐。
                Color.clear.frame(width: 28, height: 28)
            }
            content
                .padding(.top, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Branded progress chip for Fliggy realtime-search tool calls. Renders in
/// the same status area as the plain text status line; pure UI progress that
/// never persists anywhere.
private struct FliggySearchStatusChip: View {
    let progress: AgentV2FliggyProgress

    var body: some View {
        HStack(spacing: 8) {
            switch progress.phase {
            case .running:
                HStack(spacing: 6) {
                    Image(systemName: "airplane")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(PrimaryTabPalette.accent, in: Capsule())
            case .completed(let ok, _):
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ok ? .green : .orange)
            }
            Text(displayText)
                .font(.footnote)
                .foregroundStyle(PrimaryTabPalette.secondaryText)
                .lineLimit(1)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayText)
    }

    private var displayText: String {
        switch progress.phase {
        case .running:
            let title = progress.kind.progressTitle
            guard let term = progress.term, !term.isEmpty else { return title }
            return "\(title) · \(term)"
        case .completed(let ok, let count):
            if ok, let count {
                return "飞猪已返回 \(count) 个结果"
            }
            return "飞猪实时数据暂不可用，已用其他来源继续"
        }
    }
}

private struct LiveCandidateCard: View {
    let card: AgentV2LiveCard

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(card.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                ProgressView().controlSize(.mini).tint(PrimaryTabPalette.secondaryText)
            }
            if !card.timing.isEmpty { Label(card.timing, systemImage: "clock").font(.caption).foregroundStyle(PrimaryTabPalette.secondaryText) }
            if let place = card.place { Label(place, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(.white.opacity(0.85)) }
            if let reason = card.reason { Text(reason).font(.caption).foregroundStyle(PrimaryTabPalette.secondaryText) }
            Text("地点验证中").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
        }
        .padding(12)
        .primaryTabCardStyle(color: PrimaryTabPalette.elevatedSurface, cornerRadius: 15)
    }
}

private struct AgentV2CandidateCard: View {
    let candidate: AgentV2Candidate
    let selection: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { if candidate.isCommitReady { selection(!candidate.selected) } } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: candidate.selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(candidate.selected ? PrimaryTabPalette.accent : PrimaryTabPalette.tertiaryText)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Label(candidate.kind.agentTitle, systemImage: candidate.kind.agentSymbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PrimaryTabPalette.accent)
                            Spacer()
                            Text(candidate.startAt).font(.caption.monospacedDigit()).foregroundStyle(PrimaryTabPalette.secondaryText)
                        }
                        Text(candidate.title).font(.headline).foregroundStyle(.white)
                        Text(candidate.date + (candidate.place.map { " · \($0.name)" } ?? ""))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                        if let address = candidate.place?.address, !address.isEmpty {
                            Text(address).font(.caption).foregroundStyle(PrimaryTabPalette.secondaryText)
                        }
                        if let reason = candidate.reason {
                            Text(reason).font(.footnote).foregroundStyle(PrimaryTabPalette.secondaryText)
                        }
                        if !candidate.risks.isEmpty {
                            Label(candidate.risks.joined(separator: "、"), systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        HStack(spacing: 5) {
                            Image(systemName: candidate.placeStatus == .verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            Text(candidate.placeStatus.title)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(candidate.placeStatus == .verified ? .green : .orange)
                        if let priceText {
                            Label(priceText, systemImage: isRealtimePrice ? "clock.arrow.circlepath" : "banknote")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityValue(candidate.selected ? "已选择" : "未选择")
            .accessibilityHint(candidate.isCommitReady ? "轻点切换选择" : "信息完整后才可选择")

            if let xiaohongshuURL {
                Link(destination: xiaohongshuURL) {
                    Label("小红书来源 · 打开原笔记", systemImage: "arrow.up.right.square")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
                .padding(.leading, 34)
            }

            if let fliggyBookingURL {
                // Fliggy candidates carry a real booking URL. The exact price
                // lives behind the link (or degrades to a “实时价” placeholder),
                // so send the user to Safari rather than inventing a number.
                Link(destination: fliggyBookingURL) {
                    HStack(spacing: 5) {
                        Image(systemName: "airplane")
                        Text("查看预订")
                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(PrimaryTabPalette.accent, in: Capsule())
                }
                .padding(.leading, 34)
                .accessibilityLabel("在飞猪查看预订")
            }
        }
        .padding(13)
        .background(candidate.selected ? PrimaryTabPalette.accent.opacity(0.14) : PrimaryTabPalette.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(candidate.selected ? PrimaryTabPalette.accent.opacity(0.5) : Color.white.opacity(0.035), lineWidth: 1)
        }
        .opacity(candidate.isCommitReady ? 1 : 0.72)
    }

    private var xiaohongshuURL: URL? {
        guard let value = candidate.url,
              let url = URL(string: value),
              let host = url.host?.lowercased(),
              host == "xiaohongshu.com" || host.hasSuffix(".xiaohongshu.com") ||
              host == "xhslink.com" || host.hasSuffix(".xhslink.com") else { return nil }
        return url
    }

    /// Fliggy realtime candidates link to a real booking page rather than a
    /// note; only trust the known Fliggy hosts so arbitrary model URLs never
    /// render as a branded booking button.
    private var fliggyBookingURL: URL? {
        guard let value = candidate.url,
              let url = URL(string: value),
              let host = url.host?.lowercased(),
              host == "fliggy.com" || host.hasSuffix(".fliggy.com") ||
              host == "alitrip.com" || host.hasSuffix(".alitrip.com") else { return nil }
        return url
    }

    /// Price line: a concrete minor-unit amount when present, otherwise a
    /// “实时价” placeholder exactly when the server flagged that the live
    /// price lives behind the booking link. Never fabricates a number.
    private var priceText: String? {
        if let priceMinor = candidate.priceMinor {
            let major = Double(priceMinor) / 100
            let amount = major.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", major)
                : String(format: "%.2f", major)
            return "¥\(amount)"
        }
        if candidate.notes?.contains("实时价格见预订链接") == true { return "实时价" }
        return nil
    }

    private var isRealtimePrice: Bool {
        candidate.priceMinor == nil && priceText != nil
    }
}

private struct AgentContextSheet: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var store: AgentV2SessionStore
    @Environment(\.dismiss) private var dismiss

    private let interests = ["美食", "文化", "自然", "购物", "拍照", "夜生活"]

    var body: some View {
        NavigationStack {
            Form {
                Section("本次旅行") {
                    if let trip = syncEngine.trip, trip.isConfigured {
                        LabeledContent("目的地", value: trip.destination ?? "待设置")
                        LabeledContent("日期", value: "\(trip.startDate ?? "") – \(trip.endDate ?? "")")
                        LabeledContent("时区", value: TimeZone.current.identifier)
                    } else {
                        ContentUnavailableView("请先完成旅行设置", systemImage: "calendar.badge.exclamationmark", description: Text("Agent 需要目的地、日期和币种来检查地点与冲突。"))
                    }
                }

                Section("规划条件") {
                    Picker("节奏", selection: binding(\.pace)) {
                        Text("未设置").tag(""); Text("轻松").tag("relaxed"); Text("均衡").tag("balanced"); Text("特种兵").tag("packed")
                    }
                    Picker("同行人", selection: binding(\.companions)) {
                        Text("未设置").tag(""); Text("独自").tag("solo"); Text("情侣").tag("couple"); Text("带父母").tag("parents"); Text("带儿童").tag("children")
                    }
                    Picker("预算", selection: binding(\.budget)) {
                        Text("未设置").tag(""); Text("省钱").tag("value"); Text("适中").tag("balanced"); Text("品质优先").tag("premium")
                    }
                    TextField("本轮范围，例如第二天下午", text: binding(\.scope))
                }

                Section {
                    Toggle("保留未验证的模型推荐", isOn: allowUnverifiedRecommendationsBinding)
                } header: {
                    Text("地图点位")
                } footer: {
                    Text("开启后，Apple Maps 未命中的模型推荐仍会作为“地点待确认”候选，由你决定是否添加；不会伪造坐标。你原文明确写出的地点始终保留。")
                }

                Section {
                    FlowLayout(spacing: 8) {
                        ForEach(interests, id: \.self) { interest in
                            Button { toggleInterest(interest) } label: {
                                HStack(spacing: 5) {
                                    if store.session.preferences.interests.contains(interest) { Image(systemName: "checkmark") }
                                    Text(interest)
                                }
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(store.session.preferences.interests.contains(interest) ? .white : PrimaryTabPalette.secondaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(store.session.preferences.interests.contains(interest) ? PrimaryTabPalette.accent : PrimaryTabPalette.elevatedSurface, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("偏好")
                } footer: {
                    Text("条件会保存在本机，并作为每轮对话的规划前提。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(PrimaryTabPalette.background)
            .tint(PrimaryTabPalette.accent)
            .preferredColorScheme(.dark)
            .navigationTitle("旅行与偏好")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<AgentV2TurnRequest.Preferences, String?>) -> Binding<String> {
        Binding(
            get: { store.session.preferences[keyPath: keyPath] ?? "" },
            set: { value in store.updatePreference(keyPath, value: value.isEmpty ? nil : value) }
        )
    }

    private var allowUnverifiedRecommendationsBinding: Binding<Bool> {
        Binding(
            get: { store.session.preferences.retainsUnverifiedRecommendations },
            set: { store.setAllowUnverifiedRecommendations($0) }
        )
    }

    private func toggleInterest(_ interest: String) {
        store.toggleInterest(interest)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var points: [CGPoint] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight), points)
    }
}

private extension AgentV2Candidate.PlaceStatus {
    var title: String {
        switch self {
        case .verified: "地点已验证"
        case .pending: "地点验证中"
        case .failed: "地点待确认"
        case .notRequired: "无需地点"
        }
    }
}

private extension AgentV2Change {
    var operationTitle: String {
        switch operation {
        case .add: "新增"
        // 区分作用于已确认行程卡片与仅作用于未确认草稿候选的操作，
        // 避免“替换/移除”让用户误以为已确认的行程被改动。
        case .replace: targetDraftId != nil ? "更新候选" : "替换行程"
        case .remove: targetDraftId != nil ? "移除候选" : "移除行程"
        case .move: "移动"
        case .keep: "保留"
        }
    }
}

private extension AgentV2Change.Operation {
    var symbol: String {
        switch self {
        case .add: "plus.circle.fill"
        case .replace: "arrow.triangle.2.circlepath.circle.fill"
        case .remove: "minus.circle.fill"
        case .move: "arrow.up.arrow.down.circle.fill"
        case .keep: "pin.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .add: .green
        case .replace, .move: .orange
        case .remove: .red
        case .keep: PrimaryTabPalette.accent
        }
    }
}

private extension TravelCardSnapshot.Kind {
    var agentTitle: String {
        switch self {
        case .activity: "活动"
        case .hotel: "酒店"
        case .flight: "航班"
        }
    }

    var agentSymbol: String {
        switch self {
        case .activity: "figure.walk"
        case .hotel: "bed.double.fill"
        case .flight: "airplane"
        }
    }
}

struct AgentPreparedImage: Sendable {
    let data: Data
    let mediaType: String

    var dataURI: String {
        "data:\(mediaType);base64,\(data.base64EncodedString())"
    }
}

enum AgentImageAttachmentProcessor {
    static let maximumBytes = 3_000_000
    private static let maximumLongEdge: CGFloat = 4_096
    private static let minimumJPEGQuality: CGFloat = 0.2
    private static let maximumJPEGQuality: CGFloat = 0.92

    static func prepare(_ source: Data) throws -> AgentPreparedImage {
        guard !source.isEmpty else { throw AgentImageAttachmentError.unreadable }
        if source.count <= maximumBytes, let mediaType = detectedMediaType(source) {
            return AgentPreparedImage(data: source, mediaType: mediaType)
        }
        guard let original = UIImage(data: source) else { throw AgentImageAttachmentError.unreadable }

        var image = resized(original, maximumLongEdge: maximumLongEdge)
        for _ in 0 ..< 10 {
            if let data = bestJPEG(for: image, maximumBytes: maximumBytes) {
                return AgentPreparedImage(data: data, mediaType: "image/jpeg")
            }
            guard let smallest = image.jpegData(compressionQuality: minimumJPEGQuality),
                  smallest.count > maximumBytes else {
                throw AgentImageAttachmentError.compressionFailed
            }
            let ratio = min(0.88, max(0.45, sqrt(Double(maximumBytes) / Double(smallest.count)) * 0.9))
            image = resized(image, scale: CGFloat(ratio))
        }
        throw AgentImageAttachmentError.compressionFailed
    }

    private static func bestJPEG(for image: UIImage, maximumBytes: Int) -> Data? {
        guard let highQuality = image.jpegData(compressionQuality: maximumJPEGQuality) else { return nil }
        if highQuality.count <= maximumBytes { return highQuality }
        guard let lowestQuality = image.jpegData(compressionQuality: minimumJPEGQuality),
              lowestQuality.count <= maximumBytes else { return nil }

        var low = minimumJPEGQuality
        var high = maximumJPEGQuality
        var best = lowestQuality
        for _ in 0 ..< 9 {
            let quality = (low + high) / 2
            guard let candidate = image.jpegData(compressionQuality: quality) else { break }
            if candidate.count <= maximumBytes {
                best = candidate
                low = quality
            } else {
                high = quality
            }
        }
        return best
    }

    private static func resized(_ image: UIImage, maximumLongEdge: CGFloat) -> UIImage {
        let pixels = pixelSize(of: image)
        let longEdge = max(pixels.width, pixels.height)
        guard longEdge > maximumLongEdge else { return image }
        return resized(image, scale: maximumLongEdge / longEdge)
    }

    private static func resized(_ image: UIImage, scale: CGFloat) -> UIImage {
        let pixels = pixelSize(of: image)
        let target = CGSize(
            width: max(1, floor(pixels.width * scale)),
            height: max(1, floor(pixels.height * scale))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private static func pixelSize(of image: UIImage) -> CGSize {
        if let cgImage = image.cgImage {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    private static func detectedMediaType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if bytes.count >= 8, Array(bytes[0 ..< 8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return "image/png"
        }
        if bytes.count >= 12,
           String(bytes: bytes[0 ..< 4], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8 ..< 12], encoding: .ascii) == "WEBP" {
            return "image/webp"
        }
        if bytes.count >= 12,
           String(bytes: bytes[4 ..< 8], encoding: .ascii) == "ftyp" {
            let brand = String(bytes: bytes[8 ..< 12], encoding: .ascii) ?? ""
            if ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1"].contains(brand) {
                return "image/heic"
            }
        }
        return nil
    }
}

enum AgentImageAttachmentError: LocalizedError {
    case unreadable
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: "无法读取所选图片。"
        case .compressionFailed: "图片自动压缩失败，请重新选择。"
        }
    }
}
