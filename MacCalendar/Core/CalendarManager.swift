//
//  CalendarManager.swift
//  Menucal
//
//  Created by ruihelin on 2025/9/28.
//

import Combine
import SwiftUI
import EventKit

@MainActor
class CalendarManager: ObservableObject {
    @Published var calendarDays: [CalendarDay] = []
    @Published var calendarInfos: [CalendarInfo] = []
    @Published var selectedMonth: Date = Date()
    @Published var selectedDay: Date = Date()
    @Published var selectedDayLunar:String = ""
    @Published var selectedDayEvents: [CalendarEvent] = []
    @Published var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var weekdays:[String] = []

    var hasCalendarAccess: Bool {
        if #available(macOS 14.0, *) {
            return authorizationStatus == .fullAccess || authorizationStatus == .authorized
        }
        return authorizationStatus == .authorized
    }
    
    private let calendar = Calendar.Based
    private let eventStore = EKEventStore()
    private var cancellables = Set<AnyCancellable>()
    
    // 日历数据缓存，键为月份的开始日期
    private var calendarDataCache: [Date: [CalendarDay]] = [:]
    // 事件缓存，键为日期范围的开始和结束日期的字符串表示
    private var eventsCache: [String: [CalendarEvent]] = [:]
    
    init() {
        updateWeekdays()
        Task {
            await loadCalendarDays(date: selectedMonth)
            
            getSelectedDayEvents(date: Date())
            
            await loadCalendarInfo()
        }
        // 订阅日历数据库变化的通知
        subscribeToCalendarChanges()
        
        $calendarInfos
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.persistCalendarSelection()
            }
            .store(in: &cancellables)
        
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateWeekdays()
            }
            .store(in: &cancellables)
    }
    
    private func updateWeekdays() {
        var updatedWeekdays: [String]
        if SettingsManager.firstDayInWeek == .monday {
            updatedWeekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        }
        else {
            updatedWeekdays = ["周日","周一", "周二", "周三", "周四", "周五", "周六"]
        }
        
        if SettingsManager.showWeekNumber {
            updatedWeekdays.insert("", at: 0)
        }
        // Update-cache writes must not reset the month the user is browsing.
        guard weekdays != updatedWeekdays else { return }
        let hadWeekdays = !weekdays.isEmpty
        weekdays = updatedWeekdays
        guard hadWeekdays else { return }
        Task{
            await goToCurrentMonth()
        }
    }
    func resetToToday() {
        Task {
            await resetToTodayAndLoadEvents()
        }
    }

    func resetToTodayAndLoadEvents() async {
        calendarDataCache.removeAll()
        await goToCurrentMonth()
        getSelectedDayEvents(date: Date())
    }
    
    func goToCurrentMonth() async {
        selectedMonth = Date()
        await loadCalendarDays(date: selectedMonth)
    }
    
    func goToCustomizeMonth(year: Int, month: Int) {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        
        if let targetDate = Calendar.current.date(from: components) {
            
            selectedMonth = targetDate
            Task {
                await loadCalendarDays(date: targetDate)
            }
        }
    }
    
    func goToNextMonth() {
        if let nextMonth = calendar.date(byAdding: .month, value: 1, to: selectedMonth) {
            selectedMonth = nextMonth
            Task { await loadCalendarDays(date: selectedMonth) }
        }
    }
    
    func goToPreviousMonth() {
        if let prevMonth = calendar.date(byAdding: .month, value: -1, to: selectedMonth) {
            selectedMonth = prevMonth
            Task { await loadCalendarDays(date: selectedMonth) }
        }
    }
    
    func getSelectedDayEvents(date: Date) {
        selectedDay = date
        let _calendarDays = calendarDays.filter { $0.is_weekNumber == false }
        if let day = _calendarDays.first(where: { Calendar.Based.isDate($0.date!, inSameDayAs: date) }) {
            selectedDayLunar = day.full_lunar ?? ""
        } else {
            selectedDayLunar = ""
        }
        
        var events: [CalendarEvent] = []
        if let day = _calendarDays.first(where: { Calendar.Based.isDate($0.date!, inSameDayAs: date) }) {
            events = day.events
        }
        
        selectedDayEvents = events
    }
    
    func refreshEvents() {
        // 清除缓存，确保获取最新数据
        calendarDataCache.removeAll()
        eventsCache.removeAll()
        
        Task {
            await loadCalendarDays(date: selectedMonth)
            getSelectedDayEvents(date: selectedDay)
        }
    }
    
    func loadCalendarDays(date: Date) async {
        await requestAccessIfNeeded()
        
        // 获取月份的开始日期作为缓存键
        guard let monthStart = calendar.dateInterval(of: .month, for: date)?.start else {
            return
        }
        
        // 检查缓存中是否存在该月份的数据
        if let cachedDays = calendarDataCache[monthStart] {
            self.calendarDays = cachedDays
            return
        }
        
        guard hasCalendarAccess else {
            let days = await generateCalendarGrid(for: date, events: [:])
            // 缓存无事件的日历数据
            calendarDataCache[monthStart] = days
            self.calendarDays = days
            return
        }
        
        guard let gridDates = generateDateGrid(for: date),
              let firstDate = gridDates.first,
              let lastDate = gridDates.last else {
            return
        }
        
        let events = await getEventsByDate(from: firstDate, to: lastDate)
        
        let groupedEvents = groupEventsByDay(events: events)
        
        let days = await generateCalendarGrid(for: date, events: groupedEvents)
        // 缓存日历数据
        calendarDataCache[monthStart] = days
        self.calendarDays = days
    }
    
    func loadCalendarInfo() async {
        await requestAccessIfNeeded()
        guard hasCalendarAccess else { return }
        
        let allEKCalendars = eventStore.calendars(for: .event)
        
        let savedSelection = CalendarSelectionStore.decode(
            from: SettingsManager.filterCalendar,
            existingCalendarIDs: allEKCalendars.map { $0.calendarIdentifier }
        )
        
        let calendarInfos = allEKCalendars.map { calendar in
            CalendarInfo(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                color: Color(calendar.cgColor),
                // 用户显式取消勾选的日历保持关闭；未记录的新日历默认显示
                isSelected: savedSelection?[calendar.calendarIdentifier] ?? true
            )
        }
        
        self.calendarInfos = calendarInfos.sorted { $0.title < $1.title }
        
        // 日历列表或其勾选状态变化后，按最新过滤条件重新获取事件
        refreshEvents()
    }
    
    /// 用户切换某个日历的显示开关：立即持久化，避免 debounce 窗口内被 loadCalendarInfo 的旧数据覆盖。
    func setCalendarSelected(_ isSelected: Bool, calendarID: String) {
        guard let index = calendarInfos.firstIndex(where: { $0.id == calendarID }) else { return }
        calendarInfos[index].isSelected = isSelected
        persistCalendarSelection()
        refreshEvents()
    }
    
    func createEvent(event: CalendarEvent) async throws {
        guard hasCalendarAccess else {
            throw CalendarError.noPermission
        }

        guard let targetCalendar = writableCalendarForNewEvents() else {
            throw CalendarError.calendarNotModifiable
        }

        let ekEvent = EKEvent(eventStore: eventStore)
        ekEvent.calendar = targetCalendar
        ekEvent.title = event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新事件" : event.title
        ekEvent.startDate = event.startDate
        ekEvent.endDate = event.endDate
        ekEvent.isAllDay = event.isAllDay
        ekEvent.location = event.location
        ekEvent.notes = event.notes
        ekEvent.url = event.url

        do {
            try eventStore.save(ekEvent, span: .thisEvent, commit: true)
            refreshEvents()
        } catch {
            throw CalendarError.catchError(error)
        }
    }

    func updateEvent(event: CalendarEvent) async throws {
        guard hasCalendarAccess else {
            throw CalendarError.noPermission
        }
        
        guard let ekEvent = eventStore.event(withIdentifier: event.id) else {
            throw CalendarError.eventNotFound
        }
        
        guard ekEvent.calendar.allowsContentModifications else {
            throw CalendarError.calendarNotModifiable
        }
        
        ekEvent.title = event.title
        ekEvent.startDate = event.startDate
        ekEvent.endDate = event.endDate
        ekEvent.isAllDay = event.isAllDay
        ekEvent.location = event.location
        ekEvent.notes = event.notes
        ekEvent.url = event.url
        
        do {
            try eventStore.save(ekEvent, span: .thisEvent, commit: true)
            refreshEvents()
        } catch {
            throw CalendarError.catchError(error)
        }
    }
    
    func deleteEvent(withId eventId: String) async throws {
        guard hasCalendarAccess else {
            throw CalendarError.noPermission
        }
        
        guard let ekEvent = eventStore.event(withIdentifier: eventId) else {
            throw CalendarError.eventNotFound
        }
        
        guard ekEvent.calendar.allowsContentModifications else {
            throw CalendarError.calendarNotModifiable
        }
        
        do {
            try eventStore.remove(ekEvent, span: .thisEvent, commit: true)
            refreshEvents()
        } catch {
            throw CalendarError.catchError(error)
        }
    }
    
    // MARK: 私有辅助类
    
    private func writableCalendarForNewEvents() -> EKCalendar? {
        let calendars = eventStore.calendars(for: .event)
        if let selectedIDs = getFilterCalendarIds(from: calendars),
           let selectedCalendar = calendars.first(where: { selectedIDs.contains($0.calendarIdentifier) && $0.allowsContentModifications }) {
            return selectedCalendar
        }

        if let defaultCalendar = eventStore.defaultCalendarForNewEvents,
           defaultCalendar.allowsContentModifications {
            return defaultCalendar
        }

        return calendars.first { $0.allowsContentModifications }
    }

    private func subscribeToCalendarChanges() {
        NotificationCenter.default
            .publisher(for: .EKEventStoreChanged, object: eventStore)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task {
                    await self?.loadCalendarInfo()
                }
            }
            .store(in: &cancellables)
    }
    
    func requestAccessIfNeeded() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorizationStatus = status
        
        guard status == .notDetermined else { return }
        
        do {
            if #available(macOS 14.0, *) {
                _ = try await eventStore.requestFullAccessToEvents()
            } else {
                _ = try await eventStore.requestAccess(to: .event)
            }
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        } catch {
            authorizationStatus = .denied
        }
    }
    func getDisplayName(participant: EKParticipant) -> String {
        let rawName = participant.name ?? ""
        if rawName.contains("@") {
            let components = rawName.components(separatedBy: "@")
            if let firstPart = components.first, !firstPart.isEmpty {
                return firstPart
            }
        }
        return rawName
    }

    private func participantStatus(_ status: EKParticipantStatus) -> CalendarParticipantStatus {
        switch status {
        case .unknown:
            return .unknown
        case .pending:
            return .pending
        case .accepted:
            return .accepted
        case .declined:
            return .declined
        case .tentative:
            return .tentative
        case .delegated:
            return .delegated
        case .completed:
            return .completed
        case .inProcess:
            return .inProcess
        @unknown default:
            return .unknown
        }
    }
    private func getEventsByDate(from startDate: Date, to endDate: Date) async -> [CalendarEvent] {
        // 检查缓存中是否存在该日期范围的事件
        let cacheKey = "\(startDate.timeIntervalSince1970)-\(endDate.timeIntervalSince1970)"
        if let cachedEvents = eventsCache[cacheKey] {
            return cachedEvents
        }
        
        let allCalendars = eventStore.calendars(for: .event)
        // 从未保存过选择时视为显示全部日历，与 CalendarSelectionStore 的约定保持一致
        let calendarsToFetch = getFilterCalendarIds(from: allCalendars).map { ids in
            allCalendars.filter { ids.contains($0.calendarIdentifier) }
        } ?? allCalendars
        guard !calendarsToFetch.isEmpty else { return [] }
        
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendarsToFetch)
        let ekEvents = eventStore.events(matching: predicate)
        
        let events = ekEvents.map { ekEvent in
            CalendarEvent(
                id: ekEvent.eventIdentifier,
                calendar_title: ekEvent.calendar.title,
                allowsModify: ekEvent.calendar.allowsContentModifications,
                title: ekEvent.title,
                location:ekEvent.location,
                isAllDay: ekEvent.isAllDay,
                startDate: ekEvent.startDate,
                endDate: ekEvent.endDate,
                color: CodableColor(color: Color(nsColor: ekEvent.calendar.color)),
                notes: ekEvent.notes,
                url: ekEvent.url,
                organizer: ekEvent.organizer.map { CalendarEventPerson(name: $0.name, url: $0.url, status: participantStatus($0.participantStatus)) },
                attendees: ekEvent.attendees?
                    .map { participant in
                        let prettyName = getDisplayName(participant: participant)
                        return CalendarEventPerson(name: prettyName, url: participant.url, status: participantStatus(participant.participantStatus))
                    }
                    .sorted { person1, person2 in
                        let name1 = person1.name ?? ""
                        let name2 = person2.name ?? ""
                        return name1.localizedCaseInsensitiveCompare(name2) == .orderedAscending
                    }
                ?? []
            )
        }
        
        // 缓存事件数据
        eventsCache[cacheKey] = events
        return events
    }
    
    /// 持久化当前勾选状态；与已保存内容一致时跳过写入。
    /// 合并写入：日历列表暂时不完整时（账号离线、日历库未就绪），不会抹掉已有记录。
    private func persistCalendarSelection() {
        guard !calendarInfos.isEmpty else { return }
        
        var selection = CalendarSelectionStore.decode(
            from: SettingsManager.filterCalendar,
            existingCalendarIDs: calendarInfos.map { $0.id }
        ) ?? [:]
        for info in calendarInfos {
            selection[info.id] = info.isSelected
        }
        
        guard let data = CalendarSelectionStore.encode(selection),
              data != SettingsManager.filterCalendar else {
            return
        }
        
        SettingsManager.filterCalendar = data
    }
    
    private func getFilterCalendarIds(from calendars: [EKCalendar]) -> Set<String>? {
        CalendarSelectionStore.selectedCalendarIDs(
            from: SettingsManager.filterCalendar,
            existingCalendarIDs: calendars.map { $0.calendarIdentifier }
        )
    }
    
    private func groupEventsByDay(events: [CalendarEvent]) -> [Date: [CalendarEvent]] {
        var groupedEvents = [Date: [CalendarEvent]]()
        
        for event in events {
            var currentDay = calendar.startOfDay(for: event.startDate)
            while event.endDate > currentDay {
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDay) else {
                    break
                }
                if event.startDate < nextDay {
                    groupedEvents[currentDay, default: []].append(event)
                }
                currentDay = nextDay
            }
        }
        return groupedEvents
    }
    
    private func generateDateGrid(for date: Date) -> [Date]? {
        guard let monthInterval = calendar.dateInterval(of: .month, for: date) else { return nil }
        
        var gridDates: [Date] = []
        let firstDayOfMonth = monthInterval.start
        let range = calendar.range(of: .day, in: .month, for: date)!
        
        // 上个月补齐
        let firstWeekday = SettingsManager.firstDayInWeek == FirstDayInWeek.monday ? 2 : 1
        let weekdayOfFirst = calendar.component(.weekday, from: firstDayOfMonth)
        let offsetToMonday = (weekdayOfFirst - firstWeekday + 7) % 7
        if offsetToMonday > 0 {
            for i in stride(from: offsetToMonday, to: 0, by: -1) {
                if let prevDay = calendar.date(byAdding: .day, value: -i, to: firstDayOfMonth) {
                    gridDates.append(prevDay)
                }
            }
        }
        
        for i in 0..<range.count {
            if let day = calendar.date(byAdding: .day, value: i, to: firstDayOfMonth) {
                gridDates.append(day)
            }
        }
        
        // 下个月补齐
        let totalDays = gridDates.count
        let remaining = totalDays % 7
        if remaining > 0 {
            let lastDay = gridDates.last!
            for i in 1...(7 - remaining) {
                if let nextDay = calendar.date(byAdding: .day, value: i, to: lastDay) {
                    gridDates.append(nextDay)
                }
            }
        }
        
        return gridDates
    }
    private func calculateWeekOfYear(for date: Date?) -> Int {
        guard let date = date else { return 0 }
        
        var calendar = Calendar(identifier: .gregorian)
        
        calendar.locale = Locale.current
        
        calendar.firstWeekday = SettingsManager.firstDayInWeek == .monday ? 2 : 1
        
        calendar.minimumDaysInFirstWeek = 1
        
        let week = calendar.component(.weekOfYear, from: date)
        
        return week
    }
    private func generateCalendarGrid(for date: Date, events: [Date: [CalendarEvent]]) async -> [CalendarDay] {
        let lunarCalendar = Calendar(identifier: .chinese)
        let lunarMonthSymbols = ["正月","二月","三月","四月","五月","六月","七月","八月","九月","十月","冬月","腊月"]
        let lunarDaySymbols = ["初一","初二","初三","初四","初五","初六","初七","初八","初九","初十", "十一","十二","十三","十四","十五","十六","十七","十八","十九","二十", "廿一","廿二","廿三","廿四","廿五","廿六","廿七","廿八","廿九","三十"]
        
        guard let gridDates = generateDateGrid(for: date) else { return [] }
        
        var newDays: [CalendarDay] = []
        
        for day in gridDates {
            let lunarDateComponents = lunarCalendar.dateComponents(in: lunarCalendar.timeZone, from: day)
            let lunarMonth = lunarDateComponents.month ?? 1
            let lunarDay = lunarDateComponents.day ?? 1
            let lunarLeapMonth = lunarDateComponents.isLeapMonth
            
            var daysInLunarMonth = 0
            if let range = lunarCalendar.range(of: .day, in: .month, for: day) {
                daysInLunarMonth = range.count
            }
            
            let ganzhiYear = LunarDateHelper.getGanzhiYear(for: day)
            let zodiac = LunarDateHelper.getZodiac(for: day)
            let short_lunar = (lunarDay == 1) ? (lunarLeapMonth == true ? "闰" : "") + lunarMonthSymbols[lunarMonth - 1] : lunarDaySymbols[lunarDay - 1]
            let full_lunar = "\(ganzhiYear) (\(zodiac)) \((lunarLeapMonth == true ? "闰" : "") + lunarMonthSymbols[lunarMonth - 1])\(lunarDaySymbols[lunarDay - 1])"
            
            let dayStart = Calendar.Based.startOfDay(for: day)
            let dayEvents = events[dayStart] ?? []
            
            let solar_term = SolarTermHelper.getSolarTerm(for: day)
            
            let holidays = HolidayHelper.getHolidays(date: day, lunarMonth: lunarMonth, lunarDay: lunarDay, daysInLunarMonth: daysInLunarMonth)
            
            let offday = OffdayHelper.checkOffdayStatus(for: day)
            
            let is_today = Calendar.Based.isDateInToday(day)
            
            let is_currentMonth = Calendar.Based.isDate(day, equalTo: date, toGranularity: .month)
            
            newDays.append(CalendarDay(is_today: is_today, is_currentMonth: is_currentMonth, date: day, short_lunar: short_lunar, full_lunar: full_lunar, holidays: holidays, solar_term: solar_term, offday: offday, events: dayEvents))
        }
        
        var _newDays: [CalendarDay] = []
        if SettingsManager.showWeekNumber {
            let day_groups = stride(from: 0, to: newDays.count, by: 7).map {
                Array(newDays[$0..<min($0 + 7, newDays.count)])
            }
            
            for group in day_groups {
                let weekNum = calculateWeekOfYear(for: group.first?.date)
                
                let weekItem = CalendarDay(is_weekNumber: true, weekNumber: weekNum)
                
                _newDays.append(weekItem)
                _newDays.append(contentsOf: group)
            }
        } else {
            _newDays = newDays
        }
        
        return _newDays
    }
}
