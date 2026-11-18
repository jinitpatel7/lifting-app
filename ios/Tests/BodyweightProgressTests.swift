import Foundation
import XCTest
@testable import SetlineData

final class BodyweightProgressTests: XCTestCase {
    func testHistoricalAverageUsesOnlyRecordedLocalDaysAndUpdatesAfterCorrection() throws {
        func reading(_ key: String, _ kilograms: Double) throws -> BodyweightEntry {
            let day = try XCTUnwrap(WorkoutDate(key))
            return BodyweightEntry(localDate: day, createdAt: day.calendarDate, updatedAt: day.calendarDate,
                mass: try XCTUnwrap(Mass(kilograms)))
        }
        var readings = try [reading("2026-11-08", 78), reading("2026-11-03", 82),
            reading("2026-11-01", 80), reading("2026-11-15", 81)]
        XCTAssertEqual(BodyweightTrend.points(readings).map(\.smoothedKilograms), [nil, 81, 80, nil])
        readings[1].mass = try XCTUnwrap(Mass(84))
        let cutoff = try XCTUnwrap(WorkoutDate("2026-11-08"))
        let corrected = BodyweightTrend.points(readings, through: cutoff)
        XCTAssertEqual(corrected.map(\.smoothedKilograms), [nil, 82, 81])
        XCTAssertEqual(corrected.last?.entry.mass.kilograms, 78)
    }

    func testTargetsAndDeviceLinksPersistWithTheirActualWorkoutDate() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SetlineProgress-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let files = TrainingFiles(directory: directory)
            let store = try TrainingRepository(files: files, catalog: [])
            let day = try XCTUnwrap(WorkoutDate("2026-11-18"))
            let prev = day.offset(-1)
            let start = day.calendarDate.addingTimeInterval(12 * 3600)
            let rate = -2 * WeightUnit.lb.kilogramsPerUnit
            try store.saveBodyweightTarget(rate)
            XCTAssertThrowsError(try store.saveBodyweightTarget(.infinity))
            try store.saveBodyweight(try XCTUnwrap(Mass(80)), on: day)
            let readingID = store.records.bodyweight(on: day)?.id
            try store.saveBodyweight(try XCTUnwrap(Mass(79)), on: day)
            let session = try store.startEmptySession(at: start, timeZone: .gmt)
            XCTAssertThrowsError(try store.linkProgressPhotos(["asset/local"], on: prev, sessionID: session.id))
            try store.finishSession(session.id, at: start.addingTimeInterval(1))
            try store.linkProgressPhotos(["asset/local", "asset/local"], on: prev, sessionID: session.id)
            try store.linkProgressPhotos(["asset/local"], on: prev)
            try store.addPhotoReference(DevicePhotoReference(location: .appFile(relativePath: "legacy.jpg"), subject: .session(session.id)))

            let reopened = try TrainingRepository(files: files, catalog: [])
            XCTAssertEqual(reopened.records.bodyweightTargetKgPerWeek, rate)
            XCTAssertEqual(reopened.records.bodyweight(on: day)?.id, readingID)
            XCTAssertEqual(reopened.records.bodyweight(on: day)?.mass.kilograms, 79)
            XCTAssertEqual(reopened.records.progressPhotoDates, [prev, day])
            let dateLinks = reopened.records.progressPhotos(on: prev)
            let workoutLinks = reopened.records.progressPhotos(on: day)
            XCTAssertEqual(dateLinks.count, 1)
            XCTAssertEqual(workoutLinks.map(\.subject), [.session(session.id), .session(session.id)])
            XCTAssertEqual(workoutLinks.first?.localDate, day)
            try reopened.unlinkProgressPhoto(try XCTUnwrap(dateLinks.first?.id))
            try reopened.saveBodyweightTarget(nil)
            let final = try files.loadUserData()
            XCTAssertEqual(final.progressPhotoDates, [day])
            XCTAssertEqual(final.progressPhotos(on: day), workoutLinks)
            XCTAssertNil(final.bodyweightTargetKgPerWeek)
        }
    }
}
