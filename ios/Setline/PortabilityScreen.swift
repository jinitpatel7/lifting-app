import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

struct PortabilityFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText, .plainText] }
    let data: Data
    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct ShareableRoutine: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
            .suggestedFileName("setline-routine.json")
    }
}

@MainActor @Observable
final class SetlineAccountClient {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private struct Login: Codable { let username: String; let password: String }
    private struct Session: Codable { let username: String; let token: String }
    private struct ServiceError: Decodable { let error: String }
    private struct StoredBackup: Codable { let backup: SetlineBackup }
    private var session: Session?
    private var origin: URL?
    private let network = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    var username: String? { session?.username }

    func signIn(address: String, username: String, password: String, register: Bool) async throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: address), parts.scheme?.lowercased() == "https", parts.host != nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["", "/"].contains(parts.path), let url = parts.url else {
            throw TrainingDataError.invalidRecord("Enter the HTTPS address of the Setline account server.")
        }
        let data = try JSONEncoder().encode(Login(username: username, password: password))
        let result = try await send(url, path: register ? "api/account/register" : "api/account/sign-in", method: "POST", data: data, token: nil)
        session = try JSONDecoder().decode(Session.self, from: result)
        origin = url
    }

    func signOut() async throws {
        defer { session = nil; origin = nil }
        _ = try await authenticated(path: "api/account/sign-out", method: "POST")
    }
    func save(_ data: Data) async throws { _ = try await authenticated(path: "api/backup/ios", method: "PUT", data: data) }
    func backup() async throws -> SetlineBackup {
        let data = try await authenticated(path: "api/backup/ios", method: "GET")
        let result = try JSONDecoder().decode(StoredBackup.self, from: data)
        return try SetlineBackup.read(JSONEncoder().encode(result.backup))
    }
    func delete() async throws { _ = try await authenticated(path: "api/backup/ios", method: "DELETE") }

    private func authenticated(path: String, method: String, data: Data? = nil) async throws -> Data {
        guard let origin, let session else { throw TrainingDataError.invalidRecord("Sign in to manage account backups.") }
        return try await send(origin, path: path, method: method, data: data, token: session.token)
    }

    private func send(_ origin: URL, path: String, method: String, data: Data?, token: String?) async throws -> Data {
        let url = path.split(separator: "/").reduce(origin) { $0.appendingPathComponent(String($1)) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = data
        if data != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await network.data(for: request)
        guard bytes.count <= SetlineBackup.sizeLimit + 4096, let status = (response as? HTTPURLResponse)?.statusCode else {
            throw TrainingDataError.invalidRecord("The account service response is invalid.")
        }
        guard (200..<300).contains(status) else {
            if status == 401 && token != nil { session = nil; self.origin = nil }
            throw TrainingDataError.invalidRecord((try? JSONDecoder().decode(ServiceError.self, from: bytes).error) ?? "The account service could not complete the request.")
        }
        return bytes
    }
}

struct PortabilitySheet: View {
    enum Mode: Equatable { case files, account }
    private enum Review {
        case backup(SetlineBackup), routine(RoutineExchange), upload(SetlineBackup), delete
    }
    let model: TrainingModel
    let account: SetlineAccountClient
    let mode: Mode
    @Binding var appearance: Appearance
    @Binding var opaque: Bool
    @Binding var unit: WeightUnit
    @Environment(\.dismiss) private var dismiss
    @AppStorage("setlineAccountServer") private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var options = BackupOptions()
    @State private var csvOptions = ShareOptions()
    @State private var review: Review?
    @State private var importing = false
    @State private var exporting = false
    @State private var output: PortabilityFile?
    @State private var contentType: UTType = .json
    @State private var filename = "setline-backup"
    @State private var status: String?
    @State private var failed = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                if let review { reviewContent(review) }
                else if mode == .files { files }
                else { accounts }
                if busy { ProgressView() }
                if let status { Text(status).font(.subheadline).foregroundStyle(failed ? Palette.red : Palette.muted) }
            }
            .disabled(busy)
            .navigationTitle(mode == .files ? "Data portability" : "Account storage")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in safely { try prepareFile(result.get()) } }
            .fileExporter(isPresented: $exporting, document: output, contentType: contentType, defaultFilename: filename) { result in
                output = nil
                if case .failure(let error) = result { message(error.localizedDescription, error: true) }
            }
        }
    }

    private var files: some View {
        Group {
            Section("Full backup options") {
                privacyOptions
                Button("Export full backup") { safely { export(try backup().data, type: .json, name: "setline-backup") } }
            }
            Section("CSV export") {
                Toggle("Include personal notes", isOn: $csvOptions.notes)
                Toggle("Include actual effort", isOn: $csvOptions.effort)
                Button("Export workout CSV") { export(Data(TrainingCSV.workouts(model.records, options: csvOptions).utf8), type: .commaSeparatedText, name: "setline-workouts") }
                Button("Export bodyweight CSV") { export(Data(TrainingCSV.bodyweight(model.records).utf8), type: .commaSeparatedText, name: "setline-bodyweight") }
                Text("CSV uses kilograms, seconds, and meters. Bodyweight exports to a separate file.").font(.caption)
            }
            Section { Button("Choose backup or routine file") { importing = true } }
        }
    }

    private var accounts: some View {
        Group {
            Section { Text("Account storage is optional. Records stay local until you choose to save a backup to your account.") }
            if let user = account.username {
                Section("Signed in as \(user)") {
                    privacyOptions
                    Button("Review account save") { safely { review = .upload(try backup()) } }
                    Button("Get account backup") { run { review = .backup(try await account.backup()) } }
                    Button("Delete account backup", role: .destructive) { review = .delete }
                    Button("Sign out") { run { try await account.signOut(); message("Signed out.") } }
                }
            } else {
                Section("Sign in or create an account") {
                    TextField("HTTPS server address", text: $address).textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Account name", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(.password)
                    Text("New accounts require a password of at least 15 characters.").font(.caption)
                    Button("Sign in") { signIn(false) }.disabled(username.isEmpty || password.isEmpty || address.isEmpty)
                    Button("Create account") { signIn(true) }.disabled(username.isEmpty || password.count < 15 || address.isEmpty)
                }
            }
        }
    }

    private var privacyOptions: some View {
        Group {
            Toggle("Include personal notes and setup details", isOn: $options.notes)
            Toggle("Include bodyweight and its target", isOn: $options.bodyweight)
            Toggle("Include readiness check-ins", isOn: $options.readiness)
            Toggle("Include saved forecasts", isOn: $options.forecasts)
            Toggle("Include device photo references", isOn: $options.photos)
            Text("Photo files are excluded. Device photo references may be unavailable on another iPhone, or when access to the original changes.").font(.caption)
        }
    }

    @ViewBuilder private func reviewContent(_ review: Review) -> some View {
        switch review {
        case .backup(let backup):
            Section("Review backup restore") {
                Text(counts(backup))
                Text("Created \(backup.createdAt)").font(.caption)
                Text("Restore replaces your local records and settings, including \(model.records.sessions.count) workouts currently on this iPhone.")
                if model.records.activeSession != nil { Text("An active local workout will be replaced.").bold() }
                if !backup.payload.records.photos.isEmpty { Text("Photo references may require relinking on another device.").font(.caption) }
                Button("Replace local data", role: .destructive) { restore(backup) }
            }
        case .routine(let file):
            Section("Review routine import") {
                Text(file.name).font(.headline)
                ForEach(file.exercises, id: \.id) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.exercise.name).font(.subheadline.weight(.semibold))
                        if !row.equipmentLabel.isEmpty { Text(row.equipmentLabel).font(.caption) }
                        ForEach(row.warm, id: \.id) { block in Text("Warm-up · " + prescription(block)).font(.caption) }
                        ForEach(row.work, id: \.id) { block in Text("Working · " + prescription(block)).font(.caption) }
                    }
                }
                ForEach(file.groups, id: \.id) { group in Text("\(group.kind.rawValue) · \(group.rounds) rounds").font(.caption) }
                Button("Import routine") {
                    var added = false
                    if model.updateUserData({ added = try $0.importRoutine(file) }) {
                        self.review = nil
                        message(added ? "Routine imported." : "An identical routine is already saved.")
                    } else { message(model.storageError ?? "The routine could not be imported.", error: true) }
                }
            }
        case .upload(let backup):
            Section("Review account save") {
                Text(counts(backup))
                Text("This replaces the prior iPhone backup in this account. Only the selected data will be saved.")
                Button("Save to account") { run { try await account.save(backup.data); self.review = nil; message("Backup saved.") } }
            }
        case .delete:
            Section("Delete account backup") {
                Text("This deletes the saved iPhone backup. Local records stay on this device.")
                Button("Confirm delete backup", role: .destructive) { run { try await account.delete(); self.review = nil; message("Account backup deleted.") } }
            }
        }
        Button("Back") { self.review = nil; status = nil }
    }

    private func counts(_ backup: SetlineBackup) -> String {
        let records = backup.payload.records
        return "\(records.routines.count) routines · \(records.sessions.count) workouts · \(records.bodyweightEntries.count) weigh-ins · \(records.photos.count) photo references"
    }
    private func prescription(_ block: RoutineExchange.Block) -> String {
        var text = "\(block.sets) sets"
        if let reps = block.reps { text += " · \(reps.label) reps" }
        if let target = block.target {
            if let value = target.value.number {
                let suffix = switch target.kind { case "duration": "s"; case "distance": "m"; default: "kg" }
                text += " · \(value.formatted(.number.precision(.fractionLength(0...4)))) \(suffix)"
            } else if let setting = target.value.setting { text += " · Setting \(setting)" }
        }
        if block.amrap == true { text += " · AMRAP" }
        return text
    }
    private func backup() throws -> SetlineBackup {
        try SetlineBackup.make(model.records, settings: BackupDisplaySettings(appearance: appearance.rawValue.lowercased(), opaque: opaque, unit: unit), options: options)
    }
    private func restore(_ backup: SetlineBackup) {
        if model.updateUserData({ try $0.restoreBackup(backup) }) {
            let settings = backup.payload.settings
            appearance = Appearance.allCases.first { $0.rawValue.lowercased() == settings.appearance } ?? .system
            opaque = settings.opaque; unit = settings.unit
            review = nil
            message("Backup restored.")
        } else { message(model.storageError ?? "The backup could not be restored.", error: true) }
    }
    private func prepareFile(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= SetlineBackup.sizeLimit else {
            throw TrainingDataError.invalidRecord("Choose a file up to 20 MB.")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        struct Header: Decodable { let format: String }
        let header = try? JSONDecoder().decode(Header.self, from: data)
        if header?.format == "setline-routine" { review = .routine(try RoutineExchange.read(data)) }
        else { review = .backup(try SetlineBackup.read(data)) }
    }
    private func export(_ data: Data, type: UTType, name: String) {
        output = PortabilityFile(data); contentType = type; filename = name; exporting = true
    }
    private func signIn(_ register: Bool) {
        let secret = password
        password = ""
        run { try await account.signIn(address: address, username: username, password: secret, register: register); message("Signed in.") }
    }
    private func safely(_ operation: () throws -> Void) {
        status = nil
        do { try operation() } catch { message(error.localizedDescription, error: true) }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; status = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() } catch { message(error.localizedDescription, error: true) }
        }
    }
    private func message(_ value: String, error: Bool = false) { status = value; failed = error }
}

struct RoutineSharePreview: View {
    let version: RoutineVersion
    let unit: WeightUnit
    @Environment(\.dismiss) private var dismiss
    @State private var notes = false
    @State private var exporting = false
    @State private var output: PortabilityFile?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Include exercise setup and technique notes", isOn: $notes)
                    Text("The routine file contains prescriptions. Workout history, bodyweight, and photos are excluded.").font(.caption)
                }
                Section(version.name) {
                    RoutinePlanRows(version: version, unit: unit)
                    if notes {
                        ForEach(version.exercises) { row in
                            if let profile = row.variant.exercise.profile {
                                Text(([profile.setup, profile.cues] + profile.machineSetup.fields.map { "\($0.0) · \($0.1)" }).filter { !$0.isEmpty }.joined(separator: "\n"))
                            }
                        }
                    }
                }
                Button("Export routine file") {
                    do { output = PortabilityFile(try RoutineExchange(version, notes: notes).data); exporting = true }
                    catch { self.error = error.localizedDescription }
                }
                if let bytes = try? RoutineExchange(version, notes: notes).data {
                    ShareLink(item: ShareableRoutine(data: bytes), preview: SharePreview(Text(version.name), icon: Image(systemName: "doc"))) {
                        Label("Share routine file", systemImage: "square.and.arrow.up")
                    }
                }
                if let error { Text(error).foregroundStyle(Palette.red) }
            }
            .navigationTitle("Share routine")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .fileExporter(isPresented: $exporting, document: output, contentType: .json, defaultFilename: "setline-routine") { result in
                if case .failure(let error) = result { self.error = error.localizedDescription }
                output = nil
            }
        }
    }
}

struct WorkoutSharePreview: View {
    let session: WorkoutSession
    let records: TrainingRecords
    let unit: WeightUnit
    @State private var options = ShareOptions()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Included details") {
                    Toggle("Include performed sets", isOn: $options.sets)
                    Toggle("Include personal notes", isOn: $options.notes)
                    Toggle("Include same-day bodyweight", isOn: $options.bodyweight)
                    Toggle("Include actual effort", isOn: $options.effort)
                }
                Section("Preview") {
                    Text(summary).textSelection(.enabled)
                    Text("Photo files and photo references are excluded.").font(.caption)
                    ShareLink(item: summary) { Label("Share summary", systemImage: "square.and.arrow.up") }
                }
            }
            .navigationTitle("Share workout summary")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private var summary: String {
        let totals = WorkoutHistory.metrics(session)
        var lines = ["\(session.plan.name) · \(session.localDate.key)", "\(session.historyStatus.rawValue) · \(totals.sets) performed sets"]
        if let duration = totals.duration { lines.append("Duration · \((duration / 60).formatted(.number.precision(.fractionLength(0)))) min") }
        if let volume = totals.volume { lines.append("Logged volume · \(unit.display(volume, fractionDigits: 0...2)) \(unit.rawValue)·reps") }
        if options.bodyweight, let value = records.bodyweight(on: session.localDate)?.mass.kilograms {
            lines.append("Bodyweight · \(unit.display(value, fractionDigits: 0...2)) \(unit.rawValue)")
        }
        if options.notes, let notes = session.workoutLog?.notes, !notes.isEmpty { lines.append("Workout notes · " + notes) }
        for row in session.plan.exercises {
            let results = session.performedSets.filter { $0.plannedExerciseID == row.id }
            let notes = options.notes ? session.workoutLog?.exercises.first(where: { $0.id == row.id })?.notes : nil
            guard options.sets && !results.isEmpty || notes?.isEmpty == false else { continue }
            lines += ["", row.variant.exercise.name]
            if options.sets {
                for var result in results {
                    if !options.effort { result.actualRIR = nil; result.actualRPE = nil; result.effortOutcome = nil }
                    lines.append("\(result.purpose == .warmUp ? "Warm-up" : "Set") \(result.order) · \(result.summary(unit: unit, measurement: row.variant.measurement))")
                }
            }
            if let notes, !notes.isEmpty { lines.append("Exercise notes · " + notes) }
        }
        return lines.joined(separator: "\n")
    }
}
