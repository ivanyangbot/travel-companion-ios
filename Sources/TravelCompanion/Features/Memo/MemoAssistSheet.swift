import SwiftData
import SwiftUI

/// 备忘智能生成结果页：AI 依据「明日」行程给出闹钟、提醒事项和物品建议，
/// 每条都可一键落地——闹钟走 AlarmKit、提醒走 EventKit、物品写入本机清单。
struct MemoAssistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var syncEngine: SyncEngine
    @Query(sort: \LocalMemoList.updatedAt, order: .reverse) private var lists: [LocalMemoList]

    @State private var result: MemoAssistResult?
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var addedAlarmIDs: Set<UUID> = []
    @State private var addedReminderIDs: Set<UUID> = []
    @State private var addedItemIDs: Set<UUID> = []
    @State private var isAddingAll = false
    @State private var successMessage: String?
    @StateObject private var alarmScheduler = AlarmScheduler()
    @StateObject private var reminderStore = ReminderStore()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    if isGenerating {
                        ProgressView("正在生成明日建议…")
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else if let result {
                        alarmsSection(result.alarms)
                        remindersSection(result.reminders)
                        itemsSection(result.items)
                        addAllButton(result)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .padding(12)
                            .glassEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding()
            }
            .navigationTitle("明日智能建议")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .overlay {
                if isAddingAll {
                    ProgressView("正在一键写入…").padding(20)
                        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .alert("已写入", isPresented: Binding(get: { successMessage != nil }, set: { if !$0 { successMessage = nil } })) {
                Button("好", role: .cancel) { successMessage = nil }
            } message: { Text(successMessage ?? "") }
            .task { await generate() }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("依据明日行程，AI 已给出以下建议", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
            Text("点单条「添加」可分别写入；也可一键全部添加。闹钟走系统 AlarmKit，提醒写入提醒事项 App，物品进入本机清单。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func alarmsSection(_ alarms: [MemoAssistResult.Alarm]) -> some View {
        if alarms.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("闹钟建议").font(.headline)
                ForEach(alarms) { alarm in
                    suggestionCard {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alarm.title).font(.subheadline.weight(.semibold))
                                if let reason = alarm.reason, !reason.isEmpty {
                                    Text(reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(alarm.time).font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(.indigo)
                            addButton(isAdded: addedAlarmIDs.contains(alarm.id), title: "闹钟") {
                                await addAlarm(alarm)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func remindersSection(_ reminders: [MemoAssistResult.Reminder]) -> some View {
        if reminders.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("提醒建议").font(.headline)
                ForEach(reminders) { reminder in
                    suggestionCard {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(reminder.title).font(.subheadline.weight(.semibold))
                                if let notes = reminder.notes, !notes.isEmpty {
                                    Text(notes).font(.caption).foregroundStyle(.secondary)
                                }
                                if reminder.dueDate != nil || reminder.dueTime != nil {
                                    Label(dueText(reminder), systemImage: "calendar")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer(minLength: 8)
                            addButton(isAdded: addedReminderIDs.contains(reminder.id), title: "提醒") {
                                await addReminder(reminder)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func itemsSection(_ items: [MemoAssistResult.Item]) -> some View {
        if items.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("物品建议").font(.headline)
                ForEach(items) { item in
                    suggestionCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.subheadline.weight(.semibold))
                                if let category = item.category, !category.isEmpty {
                                    Text(category).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer(minLength: 8)
                            addButton(isAdded: addedItemIDs.contains(item.id), title: "物品") {
                                addItem(item)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func addAllButton(_ result: MemoAssistResult) -> some View {
        let total = result.alarms.count + result.reminders.count + result.items.count
        let done = addedAlarmIDs.count + addedReminderIDs.count + addedItemIDs.count
        if done < total {
            Button {
                Task { await addAll(result) }
            } label: {
                Label("全部添加（\(done)/\(total)）", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAddingAll)
        }
    }

    @ViewBuilder
    private func suggestionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func addButton(isAdded: Bool, title: String, action: @escaping () async -> Void) -> some View {
        if isAdded {
            Label("已添加", systemImage: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: Capsule())
        } else {
            Button {
                Task { await action() }
            } label: {
                Label("添加", systemImage: "plus")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.glass)
            .accessibilityLabel("添加\(title)")
        }
    }

    private func dueText(_ reminder: MemoAssistResult.Reminder) -> String {
        [reminder.dueDate, reminder.dueTime].compactMap { $0 }.joined(separator: " ")
    }

    private func generate() async {
        guard result == nil else { return }
        isGenerating = true
        errorMessage = nil
        do {
            result = try await syncEngine.createMemoAssist()
        } catch {
            errorMessage = error.localizedDescription
        }
        isGenerating = false
    }

    private func addAlarm(_ alarm: MemoAssistResult.Alarm) async {
        guard let fireDate = Self.combineTomorrow(time: alarm.time) else {
            errorMessage = "闹钟时间 \(alarm.time) 格式不正确，请手动设置。"
            return
        }
        let ok = await alarmScheduler.scheduleAlarm(title: alarm.title, fireDate: fireDate)
        if ok {
            addedAlarmIDs.insert(alarm.id)
        } else if let message = alarmScheduler.errorMessage {
            errorMessage = message
        }
    }

    private func addReminder(_ reminder: MemoAssistResult.Reminder) async {
        let due = Self.combineDue(date: reminder.dueDate, time: reminder.dueTime)
        let ok = await reminderStore.createReminder(title: reminder.title, notes: reminder.notes, due: due)
        if ok {
            addedReminderIDs.insert(reminder.id)
        } else if let message = reminderStore.errorMessage {
            errorMessage = message
        }
    }

    private func addItem(_ item: MemoAssistResult.Item) {
        let list = targetList()
        let position = list.items.count
        let entry = LocalMemoItem(name: item.name, position: position, category: item.category, notes: nil)
        list.items.append(entry)
        list.updatedAt = .now
        do {
            try modelContext.save()
            addedItemIDs.insert(item.id)
        } catch {
            errorMessage = "无法保存物品：\(error.localizedDescription)"
        }
    }

    private func addAll(_ result: MemoAssistResult) async {
        isAddingAll = true
        for alarm in result.alarms where !addedAlarmIDs.contains(alarm.id) {
            await addAlarm(alarm)
        }
        for reminder in result.reminders where !addedReminderIDs.contains(reminder.id) {
            await addReminder(reminder)
        }
        for item in result.items where !addedItemIDs.contains(item.id) {
            addItem(item)
        }
        isAddingAll = false
        let total = addedAlarmIDs.count + addedReminderIDs.count + addedItemIDs.count
        successMessage = "已写入 \(total) 项建议。闹钟可在 AlarmKit 闹钟页查看，提醒在系统提醒事项 App 查看。"
    }

    /// 物品建议默认并入最近编辑过的清单；若没有任何清单则新建一条「AI 建议」。
    private func targetList() -> LocalMemoList {
        if let first = lists.first { return first }
        let newList = LocalMemoList(title: "AI 建议物品", symbol: "sparkles")
        modelContext.insert(newList)
        try? modelContext.save()
        return newList
    }

    /// 把 HH:mm 拼到「明日」上，按设备本地时区生成触发时刻。
    private static func combineTomorrow(time: String) -> Date? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0 ... 23).contains(hour), (0 ... 59).contains(minute) else { return nil }
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) else { return nil }
        let components = DateComponents(calendar: calendar, timeZone: calendar.timeZone, hour: hour, minute: minute)
        return calendar.nextDate(after: .now, matching: components, matchingPolicy: .nextTime)
            ?? calendar.date(bySettingHour: hour, minute: minute, second: 0, of: tomorrow)
    }

    /// 把 yyyy-MM-dd 与可选 HH:mm 组合为具体触发时刻；仅有日期时取当日 09:00。
    private static func combineDue(date: String?, time: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let datePart = date ?? Self.todayDateString()
        let timePart = time?.isEmpty == false ? time! : "09:00"
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(datePart) \(timePart)")
    }

    private static func todayDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }
}
