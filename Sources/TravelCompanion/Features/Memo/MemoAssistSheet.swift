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
                        ProgressView("memoassist.generating")
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
            .navigationTitle("memoassist.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.close") { dismiss() } }
            }
            .overlay {
                if isAddingAll {
                    ProgressView("memoassist.writing").padding(20)
                        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .alert("memoassist.writtenTitle", isPresented: Binding(get: { successMessage != nil }, set: { if !$0 { successMessage = nil } })) {
                Button("common.ok", role: .cancel) { successMessage = nil }
            } message: { Text(successMessage ?? "") }
            .task { await generate() }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("memoassist.intro", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
            Text("memoassist.caption")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func alarmsSection(_ alarms: [MemoAssistResult.Alarm]) -> some View {
        if alarms.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("memoassist.alarmSection").font(.headline)
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
                            addButton(isAdded: addedAlarmIDs.contains(alarm.id), title: String(localized: "memoassist.alarmAdd")) {
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
                Text("memoassist.reminderSection").font(.headline)
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
                            addButton(isAdded: addedReminderIDs.contains(reminder.id), title: String(localized: "memoassist.reminderAdd")) {
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
                Text("memoassist.itemSection").font(.headline)
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
                            addButton(isAdded: addedItemIDs.contains(item.id), title: String(localized: "memoassist.itemAdd")) {
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
                Label(String(format: String(localized: "memoassist.addAll"), done, total), systemImage: "wand.and.stars")
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
            Label("memoassist.addedLabel", systemImage: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: Capsule())
        } else {
            Button {
                Task { await action() }
            } label: {
                Label("memoassist.addButton", systemImage: "plus")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.glass)
            .accessibilityLabel(Text(String(format: String(localized: "memoassist.addA11y"), title)))
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
            errorMessage = String(format: String(localized: "memoassist.alarmBadFormat"), alarm.time)
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
            errorMessage = String(format: String(localized: "memoassist.itemSaveFailed"), error.localizedDescription)
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
        successMessage = String(format: String(localized: "memoassist.writtenSummary"), total)
    }

    /// 物品建议默认并入最近编辑过的清单；若没有任何清单则新建一条「AI 建议」。
    private func targetList() -> LocalMemoList {
        if let first = lists.first { return first }
        let newList = LocalMemoList(title: String(localized: "memoassist.aiListTitle"), symbol: "sparkles")
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
