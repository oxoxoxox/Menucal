//
//  CalendarSelectionStore.swift
//  MacCalendar
//

import Foundation

/// 日历显示选择的持久化与解析。
///
/// 存储格式（UserDefaults key `filterCalendar`）：
/// - 当前版本：`[日历ID: 是否显示]`，会显式记录用户取消勾选的日历
/// - 旧版本：`[已勾选的日历ID]`，未列出的日历视为已取消勾选
enum CalendarSelectionStore {
    /// 编码每个日历的显示状态。
    /// 使用 sortedKeys 保证相同选择产生相同字节，便于与已保存内容比较、跳过无变化的写入。
    static func encode(_ selection: [String: Bool]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(selection)
    }

    /// 解析每个日历的显示状态；从未保存过有效选择时返回 nil（视为全部显示）。
    /// 返回结果覆盖 `existingCalendarIDs`：未记录的日历（例如系统里新建的日历）默认显示。
    static func decode(from data: Data, existingCalendarIDs: [String]) -> [String: Bool]? {
        if let selection = try? JSONDecoder().decode([String: Bool].self, from: data), !selection.isEmpty {
            var resolved = selection
            for id in existingCalendarIDs where resolved[id] == nil {
                resolved[id] = true
            }
            return resolved
        }

        if let selectedIDs = try? JSONDecoder().decode([String].self, from: data), !selectedIDs.isEmpty {
            let selected = Set(selectedIDs)
            return Dictionary(uniqueKeysWithValues: existingCalendarIDs.map { ($0, selected.contains($0)) })
        }

        return nil
    }

    /// 返回已勾选的日历 ID；nil 表示从未保存过选择（视为全部日历）。
    /// 注意：全部取消勾选时返回空集合而非 nil，表示不显示任何日历。
    static func selectedCalendarIDs(from data: Data, existingCalendarIDs: [String]) -> Set<String>? {
        guard let selection = decode(from: data, existingCalendarIDs: existingCalendarIDs) else { return nil }
        return Set(selection.filter { $0.value }.keys)
    }
}
