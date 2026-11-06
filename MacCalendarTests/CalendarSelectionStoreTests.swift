//
//  CalendarSelectionStoreTests.swift
//  MacCalendarTests
//

import XCTest
@testable import Menucal

@MainActor
final class CalendarSelectionStoreTests: XCTestCase {
    private let existingIDs = ["A", "B", "C"]
    
    private func encoded(_ selection: [String: Bool]) throws -> Data {
        try XCTUnwrap(CalendarSelectionStore.encode(selection))
    }
    
    func testEmptyDataMeansAllCalendars() {
        XCTAssertNil(CalendarSelectionStore.decode(from: Data(), existingCalendarIDs: existingIDs))
        XCTAssertNil(CalendarSelectionStore.selectedCalendarIDs(from: Data(), existingCalendarIDs: existingIDs))
    }
    
    func testRoundTripKeepsDeselectedCalendars() throws {
        let selection = ["A": true, "B": false, "C": true]
        let data = try encoded(selection)
        
        XCTAssertEqual(CalendarSelectionStore.decode(from: data, existingCalendarIDs: existingIDs), selection)
        XCTAssertEqual(
            CalendarSelectionStore.selectedCalendarIDs(from: data, existingCalendarIDs: existingIDs),
            Set(["A", "C"])
        )
    }
    
    func testUnrecordedCalendarDefaultsToVisible() throws {
        let data = try encoded(["A": false])
        
        XCTAssertEqual(
            CalendarSelectionStore.decode(from: data, existingCalendarIDs: existingIDs),
            ["A": false, "B": true, "C": true]
        )
    }
    
    func testLegacyArrayMigratesToPerCalendarSelection() throws {
        let legacy = try JSONEncoder().encode(["A", "C"])
        
        XCTAssertEqual(
            CalendarSelectionStore.decode(from: legacy, existingCalendarIDs: existingIDs),
            ["A": true, "B": false, "C": true]
        )
        XCTAssertEqual(
            CalendarSelectionStore.selectedCalendarIDs(from: legacy, existingCalendarIDs: existingIDs),
            Set(["A", "C"])
        )
    }
    
    func testLegacyEmptyArrayMeansAllCalendars() throws {
        let legacy = try JSONEncoder().encode([String]())
        
        XCTAssertNil(CalendarSelectionStore.decode(from: legacy, existingCalendarIDs: existingIDs))
    }
    
    func testAllDeselectedIsEmptySetNotNil() throws {
        let data = try encoded(["A": false, "B": false, "C": false])
        
        XCTAssertEqual(
            CalendarSelectionStore.selectedCalendarIDs(from: data, existingCalendarIDs: existingIDs),
            Set<String>()
        )
        XCTAssertNotNil(CalendarSelectionStore.selectedCalendarIDs(from: data, existingCalendarIDs: existingIDs))
    }
    
    func testEncodingIsIndependentOfDictionaryOrder() throws {
        let first = try encoded(["A": true, "B": false, "C": true])
        let second = try encoded(["C": true, "B": false, "A": true])
        
        XCTAssertEqual(first, second)
    }
    
    func testUnknownCalendarIDsArePreserved() throws {
        let data = try encoded(["Z": true, "A": false])
        
        XCTAssertEqual(
            CalendarSelectionStore.decode(from: data, existingCalendarIDs: ["A"]),
            ["Z": true, "A": false]
        )
    }
}
