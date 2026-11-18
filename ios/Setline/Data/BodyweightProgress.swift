import Foundation

struct BodyweightTrendPoint: Identifiable {
    let entry: BodyweightEntry
    let smoothedKilograms: Double?
    var id: UUID { entry.id }
}

enum BodyweightTrend {
    static func points(_ entries: [BodyweightEntry], through end: WorkoutDate? = nil) -> [BodyweightTrendPoint] {
        let ordered = entries.filter { entry in end.map { entry.localDate <= $0 } ?? true }.sorted { $0.localDate < $1.localDate }
        var first = 0
        return ordered.enumerated().map { index, entry in
            while ordered[first].localDate.distance(to: entry.localDate) >= 7 { first += 1 }
            let window = ordered[first...index]
            let average = window.count < 2 ? nil : window.reduce(0.0) { $0 + $1.mass.kilograms / Double(window.count) }
            return BodyweightTrendPoint(entry: entry, smoothedKilograms: average)
        }
    }
}

extension TrainingRepository {
    func saveBodyweightTarget(_ kgPerWeek: Double?) throws {
        guard kgPerWeek?.isFinite != false else {
            throw TrainingDataError.invalidRecord("Enter a valid weekly rate of change.")
        }
        try commit { $0.bodyweightTargetKgPerWeek = kgPerWeek }
    }
}

extension TrainingRecords {
    func progressPhotoDate(_ photo: DevicePhotoReference) -> WorkoutDate? {
        if case .session(let id) = photo.subject {
            return sessions.first { $0.id == id }?.localDate ?? photo.localDate
        }
        return photo.subject == nil ? photo.localDate : nil
    }

    func progressPhotos(on day: WorkoutDate) -> [DevicePhotoReference] {
        photos.filter { progressPhotoDate($0) == day }
    }

    var progressPhotoDates: [WorkoutDate] { Set(photos.compactMap(progressPhotoDate)).sorted() }
}

extension TrainingRepository {
    func linkProgressPhotos(_ identifiers: [String], on day: WorkoutDate, sessionID: UUID? = nil) throws {
        let subject = sessionID.map(PhotoSubject.session)
        let date: WorkoutDate
        if let sessionID {
            guard let session = records.sessions.first(where: { $0.id == sessionID && $0.completedAt != nil }) else {
                throw TrainingDataError.unknownRecord("Choose a finished workout for these photos.")
            }
            date = session.localDate
        } else {
            date = day
        }
        let locations = identifiers.map { PhotoLocation.photoLibrary(localIdentifier: $0) }
        guard !locations.isEmpty, locations.allSatisfy(\.isValid) else {
            throw TrainingDataError.invalidRecord("Choose an image with a device photo reference.")
        }
        try commit { next in
            for location in locations {
                let alreadyLinked = next.photos.contains { photo in
                    photo.location == location && photo.subject == subject && next.progressPhotoDate(photo) == date
                }
                if !alreadyLinked { next.photos.append(DevicePhotoReference(location: location, subject: subject, localDate: date)) }
            }
        }
    }

    func unlinkProgressPhoto(_ id: UUID) throws {
        guard let photo = records.photos.first(where: { $0.id == id }), records.progressPhotoDate(photo) != nil else { return }
        try commit { $0.photos.removeAll { $0.id == id } }
    }
}
