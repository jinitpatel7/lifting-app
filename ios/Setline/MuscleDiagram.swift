import SwiftUI

struct AnatomyReference: Decodable {
    struct Region: Decodable {
        let name: String
        let muscles: [String]
    }

    struct Part: Decodable {
        let points: [[Double]]
        let group: MuscleGroup?
        let mirror: Bool?
    }

    let regions: [String: Region]
    let neutral: [Part]
    let front: [Part]
    let back: [Part]

    static let bundled: Self? = {
        guard let url = Bundle.main.url(forResource: "MuscleRegions", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }()
}

private struct MuscleShape: Shape {
    let part: AnatomyReference.Part

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = part.points.filter { $0.count == 2 }
        func addPolygon(mirrored: Bool) {
            for (index, point) in points.enumerated() {
                let x = mirrored ? 120 - point[0] : point[0]
                let position = CGPoint(x: rect.minX + CGFloat(x / 120) * rect.width,
                                       y: rect.minY + CGFloat(point[1] / 236) * rect.height)
                if index == 0 { path.move(to: position) }
                else { path.addLine(to: position) }
            }
            path.closeSubpath()
        }
        addPolygon(mirrored: false)
        if part.mirror == true { addPolygon(mirrored: true) }
        return path
    }
}

struct InteractiveMuscleMap: View {
    let involvement: MuscleInvolvement
    var browse: ((MuscleGroup) -> Void)? = nil
    @State private var selection: MuscleGroup?

    private let primary = Color(hex: 0x7548ED)
    private let secondary = Color(hex: 0xE4788D)
    private let neutral = Color(hex: 0xD8D2E3)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardHeading(title: "Muscle map")
                Spacer()
                IconTile(symbol: "figure.stand", size: 32)
            }
            if let anatomy = AnatomyReference.bundled {
                HStack(alignment: .top, spacing: 10) {
                    figure("Front", anatomy: anatomy, parts: anatomy.front)
                    figure("Back", anatomy: anatomy, parts: anatomy.back)
                }
                .frame(maxWidth: 340)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
                HStack(alignment: .top, spacing: 14) {
                    key("Primary", tint: primary, groups: involvement.primary)
                    key("Secondary", tint: secondary, groups: involvement.secondary)
                }
                if involvement.isEmpty {
                    Text("No planned muscle targets").font(.caption).foregroundStyle(Palette.muted)
                }
                Menu {
                    ForEach(MuscleGroup.allCases) { muscle in
                        Button(anatomy.regions[muscle.rawValue]?.name ?? muscle.label) { selection = muscle }
                    }
                } label: {
                    Label("Select muscle region", systemImage: "scope")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .foregroundStyle(Palette.purple)
                if let selection, let region = anatomy.regions[selection.rawValue] {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(region.name).font(.headline)
                        Text(region.muscles.joined(separator: " · ")).font(.subheadline).foregroundStyle(Palette.muted)
                        if involvement.primary.contains(selection) { Text("Primary involvement").font(.caption.weight(.bold)) }
                        if involvement.secondary.contains(selection) { Text("Secondary involvement").font(.caption.weight(.bold)) }
                        if let browse {
                            Button("Browse \(region.name.lowercased()) exercises") { browse(selection) }
                                .buttonStyle(SecondaryButton())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Palette.soft, in: RoundedRectangle(cornerRadius: 10))
                }
            } else {
                Text("Muscle diagram unavailable").font(.subheadline).foregroundStyle(Palette.muted)
            }
        }
        .padding(14).surface()
    }

    private func figure(_ label: String, anatomy: AnatomyReference, parts: [AnatomyReference.Part]) -> some View {
        VStack(spacing: 3) {
            ZStack {
                ForEach(anatomy.neutral.indices, id: \.self) { index in
                    MuscleShape(part: anatomy.neutral[index]).fill(neutral).allowsHitTesting(false)
                }
                ForEach(parts.indices, id: \.self) { index in
                    let part = parts[index]
                    if let group = part.group {
                        let shape = MuscleShape(part: part)
                        Button { selection = group } label: {
                            shape.fill(fill(group))
                                .overlay { shape.stroke(selection == group ? Palette.purple : Palette.surface, lineWidth: selection == group ? 2 : 1) }
                                .contentShape(shape)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .aspectRatio(120.0 / 236.0, contentMode: .fit)
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
        }
    }

    private func fill(_ muscle: MuscleGroup) -> Color {
        if involvement.primary.contains(muscle) { return primary }
        if involvement.secondary.contains(muscle) { return secondary }
        return neutral
    }

    private func key(_ title: String, tint: Color, groups: Set<MuscleGroup>) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(tint).frame(width: 8, height: 8).padding(.top, 4).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                if !groups.isEmpty {
                    Text(MuscleGroup.allCases.filter(groups.contains).map(\.label).joined(separator: ", "))
                        .font(.caption).foregroundStyle(Palette.muted)
                }
            }
        }
    }
}
