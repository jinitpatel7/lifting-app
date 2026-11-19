import Foundation

struct RoutineExchange: Codable {
    enum Value: Codable, Equatable {
        case numberValue(Double), settingValue(String)
        var number: Double? { if case .numberValue(let value) = self { value } else { nil } }
        var setting: String? { if case .settingValue(let value) = self { value } else { nil } }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) { self = .numberValue(value) }
            else { self = .settingValue(try container.decode(String.self)) }
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .numberValue(let value): try container.encode(value)
            case .settingValue(let value): try container.encode(value)
            }
        }
    }

    struct Amount: Codable, Equatable {
        let kind: String
        let value: Value
        func typed(for measurement: Measurement) throws -> SetAmount {
            let result: SetAmount?
            if kind == "setting", let setting = value.setting { result = .machineSetting(setting) }
            else if let number = value.number {
                result = switch kind {
                case "weight": Mass(number).map(SetAmount.weight)
                case "added": Mass(number).map(SetAmount.addedLoad)
                case "assistance": Mass(number).map(SetAmount.assistance)
                case "duration": .durationSeconds(number)
                case "distance": .distanceMeters(number)
                default: nil
                }
            } else { result = nil }
            guard let result, measurement.accepts(result) else { throw invalid("A target does not match the exercise measurement.") }
            return result
        }
    }

    struct Effort: Codable, Equatable { let kind: String; let value: Double? }

    struct Block: Codable, Equatable {
        var id: String
        let sets: Int
        let reps: RepRange?
        let target: Amount?
        let rest: Int?
        let structure: String?
        let amrap: Bool?
        let effort: Effort?

        init(_ set: SetPrescription) {
            id = UUID().uuidString
            sets = set.sets; reps = set.reps; target = RoutineExchange.amount(set.target); rest = set.restSeconds
            structure = switch set.structure { case .dropSet: "dropSet"; case .restPause: "restPause"; default: "straight" }
            amrap = set.amrap == true
            effort = switch set.effort {
            case .rpe(let value): Effort(kind: "rpe", value: value)
            case .failure: Effort(kind: "failure", value: nil)
            case nil: set.repsInReserve.map { Effort(kind: "rir", value: Double($0)) }
            }
        }

        func prescription(_ measurement: Measurement) throws -> SetPrescription {
            let structure: SetStructure?
            switch self.structure {
            case "straight", nil: structure = nil
            case "dropSet": structure = .dropSet
            case "restPause": structure = .restPause
            default: throw invalid("An unsupported set structure is present.")
            }
            var rir: Int?, targetEffort: EffortTarget?
            if let effort {
                switch effort.kind {
                case "failure": targetEffort = .failure
                case "rir":
                    guard let value = effort.value.flatMap({ Int(exactly: $0) }), value >= 0 else { throw invalid("An RIR target is invalid.") }
                    rir = value
                case "rpe":
                    guard let value = effort.value, (1...10).contains(value) else { throw invalid("An RPE target is invalid.") }
                    targetEffort = .rpe(value)
                default: throw invalid("An effort target is invalid.")
                }
            }
            let set = SetPrescription(sets: sets, reps: reps, target: try target?.typed(for: measurement), repsInReserve: rir,
                restSeconds: rest, structure: structure, amrap: amrap == true ? true : nil, effort: targetEffort)
            guard (1...10_000).contains(sets), set.isValid(for: measurement) else { throw invalid("A set prescription is invalid.") }
            return set
        }
    }

    struct ExerciseInfo: Codable {
        var id: String
        let name: String
        let equipment: EquipmentKind?
        let variation: String?
        let pattern: MovementPattern?
        let primary: [MuscleGroup]?
        let secondary: [MuscleGroup]?
        let setup: String?
        let cues: String?
        let machineSetup: [String: String]?

        var profile: ExerciseProfile {
            ExerciseProfile(pattern: pattern ?? .other, equipmentKind: equipment, variation: variation ?? "", primary: primary ?? [],
                secondary: secondary ?? [], setup: setup ?? "", cues: cues ?? "", machineSetup: MachineSetup(seat: machineSetup?["seat"] ?? "",
                    attachment: machineSetup?["attachment"] ?? "", incline: machineSetup?["incline"] ?? "", handle: machineSetup?["handle"] ?? ""))
        }
    }

    struct Row: Codable {
        let id: String
        let exercise: ExerciseInfo
        let equipmentLabel: String
        let measurement: String
        let basis: String
        let counting: String
        let warm: [Block]
        let work: [Block]

        var selectedMeasurement: Measurement { get throws {
            guard let basis = LoadBasis(rawValue: basis), let counting = RepCounting(rawValue: counting) else {
                throw invalid("An exercise has unsupported loading or rep conventions.")
            }
            switch measurement {
            case "weight": return .weightReps(basis: basis, reps: counting)
            case "added": return .addedLoad(reps: counting)
            case "assistance": return .assistance(reps: counting)
            case "bodyweight": return .bodyweight(reps: counting)
            case "duration": return .duration
            case "distance": return .distance
            case "setting": return .machineSetting(reps: counting)
            default: throw invalid("An exercise has an unsupported measurement.")
            }
        } }

        var resolvedLabel: String {
            let value = equipmentLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty && measurement == "weight" && basis == "perDumbbell" { return "Dumbbell" }
            return value
        }

        var equipmentKind: EquipmentKind? { exercise.equipment ?? (measurement == "setting" ? .machine : nil) }
    }

    struct Group: Codable {
        let id: String
        let kind: RoutineGroup.Kind
        let members: [String]
        let rounds: Int
        let restExercises: Int
        let restRounds: Int
    }

    let format: String
    let version: Int
    let name: String
    let exercises: [Row]
    let groups: [Group]

    init(_ source: RoutineVersion, notes: Bool) {
        format = "setline-routine"; version = 1; name = source.name
        exercises = source.exercises.map { entry in
            let exercise = entry.variant.exercise, profile = exercise.profile
            let wire = Self.measurement(entry.variant.measurement)
            let setup = profile?.machineSetup
            let machine = setup.map { ["seat": $0.seat, "attachment": $0.attachment, "incline": $0.incline, "handle": $0.handle] }
            let info = ExerciseInfo(id: exercise.id.uuidString, name: exercise.name, equipment: entry.variant.equipment?.kind ?? profile?.equipmentKind,
                variation: profile?.variation, pattern: profile?.pattern, primary: profile?.primary, secondary: profile?.secondary,
                setup: notes ? profile?.setup : nil, cues: notes ? profile?.cues : nil, machineSetup: notes ? machine : nil)
            return Row(id: entry.id.uuidString, exercise: info, equipmentLabel: entry.variant.equipment?.name ?? "", measurement: wire.kind,
                basis: wire.basis, counting: wire.counting, warm: (entry.warmUps ?? []).map(Block.init), work: entry.workingSets.map(Block.init))
        }
        groups = (source.groups ?? []).map { Group(id: $0.id.uuidString, kind: $0.kind, members: $0.exerciseIDs.map(\.uuidString),
            rounds: $0.rounds, restExercises: $0.restBetweenExercises, restRounds: $0.restBetweenRounds) }
    }

    var data: Data { get throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= SetlineBackup.sizeLimit else { throw invalid("The routine exceeds the 20 MB limit.") }
        return bytes
    } }

    static func read(_ bytes: Data) throws -> Self {
        guard bytes.count <= SetlineBackup.sizeLimit, let result = try? JSONDecoder().decode(Self.self, from: bytes) else { throw invalid("The routine file is malformed.") }
        try result.validate()
        return result
    }

    private func validate() throws {
        guard format == "setline-routine", version == 1, Self.named(name), !exercises.isEmpty,
              Set(exercises.map(\.id)).count == exercises.count, Set(groups.map(\.id)).count == groups.count else {
            throw invalid("This routine has an unsupported version or duplicate or missing exercise slots.")
        }
        for row in exercises {
            let measurement = try row.selectedMeasurement
            guard Self.named(row.exercise.name), !row.id.isEmpty, !row.exercise.id.isEmpty, row.equipmentLabel.count <= 240, !row.work.isEmpty,
                  row.measurement != "setting" || !row.resolvedLabel.isEmpty,
                  row.measurement != "weight" || row.basis != "perDumbbell" || row.exercise.equipment == .dumbbell else {
                throw invalid("An exercise is missing its name, targets, or compatible equipment.")
            }
            let blocks = row.warm + row.work
            guard Set(blocks.map(\.id)).count == blocks.count else { throw invalid("Duplicate set identifiers.") }
            var remaining = 10_000
            for block in blocks {
                _ = try block.prescription(measurement)
                remaining -= block.sets
                guard remaining >= 0 else { throw invalid("An exercise contains too many sets.") }
            }
        }
        let positions = Dictionary(uniqueKeysWithValues: exercises.enumerated().map { ($0.element.id, $0.offset) })
        var occupied = Set<String>()
        for group in groups {
            let indices = group.members.compactMap { positions[$0] }.sorted()
            guard group.rounds > 0, group.restExercises >= 0, group.restRounds >= 0, indices.count == group.members.count,
                  indices.count >= 2, group.kind != .superset || indices.count == 2, let start = indices.first,
                  indices.enumerated().allSatisfy({ $0.element == start + $0.offset }),
                  occupied.isDisjoint(with: group.members) else { throw invalid("A superset or circuit has invalid membership or timing.") }
            occupied.formUnion(group.members)
        }
    }

    func insert(into records: inout TrainingRecords, catalog: [Exercise]) throws -> Bool {
        try validate()
        let canonical = try fingerprint()
        for current in records.currentRoutines {
            if try RoutineExchange(current, notes: false).fingerprint() == canonical { return false }
        }
        var resolved: [String: Exercise] = [:]
        var slotIDs: [String: UUID] = [:]
        var rows: [PlannedExercise] = []
        for row in exercises {
            let info = row.exercise
            let existing = UUID(uuidString: info.id).flatMap { id in (catalog + records.exercises).first { $0.id == id } }
            let exercise: Exercise
            if let cached = resolved[info.id] { exercise = cached }
            else if let existing, existing.profile?.equipmentKind == row.equipmentKind,
                    (existing.profile?.variation ?? "") == (info.variation ?? ""), existing.name == info.name { exercise = existing }
            else {
                var profile = info.profile
                profile.equipmentKind = row.equipmentKind
                exercise = Exercise(name: info.name, profile: profile)
                records.exercises.append(exercise)
            }
            resolved[info.id] = exercise
            let measurement = try row.selectedMeasurement
            let equipment: Equipment?
            if let kind = row.equipmentKind, !row.resolvedLabel.isEmpty {
                if let existing = records.equipment.first(where: { $0.name == row.resolvedLabel && $0.kind == kind }) { equipment = existing }
                else {
                    let item = Equipment(name: row.resolvedLabel, kind: kind)
                    equipment = item; records.equipment.append(item)
                }
            } else { equipment = nil }
            guard measurement.supports(equipment) else { throw invalid("An exercise has incompatible equipment.") }
            let work = try row.work.map { try $0.prescription(measurement) }
            let warm = try row.warm.map { try $0.prescription(measurement) }
            let entry = PlannedExercise(variant: ExerciseVariant(exercise: exercise, equipment: equipment, measurement: measurement), prescription: work[0],
                warmUps: warm.isEmpty ? nil : warm, additionalWorkingSets: work.count > 1 ? Array(work.dropFirst()) : nil)
            slotIDs[row.id] = entry.id
            rows.append(entry)
        }
        let mapped = groups.map { group in RoutineGroup(kind: group.kind, exerciseIDs: group.members.compactMap { slotIDs[$0] }, rounds: group.rounds,
            restBetweenExercises: group.restExercises, restBetweenRounds: group.restRounds) }
        let id = UUID()
        let created = Date()
        let plan = RoutineVersion(routineID: id, revision: 1, createdAt: created, name: name, exercises: rows,
            groups: mapped.isEmpty ? nil : try RoutineGroup.normalized(mapped, exercises: rows))
        records.routineVersions.append(plan)
        records.routines.append(RoutineRecord(id: id, createdAt: created, currentVersionID: plan.id))
        return true
    }

    private func fingerprint() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func normalized(_ block: Block) throws -> [String: Any] {
            var result = try (JSONSerialization.jsonObject(with: encoder.encode(block)) as? [String: Any]) ?? [:]
            result.removeValue(forKey: "id")
            result["structure"] = block.structure ?? "straight"
            result["amrap"] = block.amrap == true
            return result
        }
        let rows: [[String: Any]] = try exercises.map { row in ["name": row.exercise.name, "equipment": row.equipmentKind?.rawValue ?? "",
            "variation": row.exercise.variation ?? "", "label": row.resolvedLabel, "measurement": row.measurement, "basis": row.basis,
            "counting": row.counting, "warm": try row.warm.map(normalized), "work": try row.work.map(normalized)] }
        let mapped: [[String: Any]] = groups.map { group in ["kind": group.kind.rawValue,
            "members": group.members.compactMap { id in exercises.firstIndex { $0.id == id } }.sorted(), "rounds": group.rounds,
            "restExercises": group.restExercises, "restRounds": group.restRounds] }
        return try JSONSerialization.data(withJSONObject: ["name": name, "exercises": rows, "groups": mapped], options: .sortedKeys)
    }

    static func measurement(_ measurement: Measurement) -> (kind: String, basis: String, counting: String) {
        let counting = measurement.repCounting?.rawValue ?? "total"
        return switch measurement {
        case .weightReps(let basis, _): ("weight", basis.rawValue, counting)
        case .bodyweight: ("bodyweight", "total", counting)
        case .addedLoad: ("added", "total", counting)
        case .assistance: ("assistance", "total", counting)
        case .duration: ("duration", "total", counting)
        case .distance: ("distance", "total", counting)
        case .machineSetting: ("setting", "total", counting)
        }
    }

    static func amount(_ amount: SetAmount?) -> Amount? {
        switch amount {
        case .weight(let mass): Amount(kind: "weight", value: .numberValue(mass.kilograms))
        case .addedLoad(let mass): Amount(kind: "added", value: .numberValue(mass.kilograms))
        case .assistance(let mass): Amount(kind: "assistance", value: .numberValue(mass.kilograms))
        case .durationSeconds(let seconds): Amount(kind: "duration", value: .numberValue(seconds))
        case .distanceMeters(let meters): Amount(kind: "distance", value: .numberValue(meters))
        case .machineSetting(let setting): Amount(kind: "setting", value: .settingValue(setting))
        case nil: nil
        }
    }

    private static func named(_ value: String) -> Bool { value.count <= 240 && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private func invalid(_ detail: String) -> TrainingDataError { .invalidRecord(detail) }
