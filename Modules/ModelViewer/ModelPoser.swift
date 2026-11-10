import SceneKit

// Per-model setup, written once per model (by hand or by the chat that built the asset) at
// ~/Library/Application Support/TaruTweaks/ModelViewer/<file name>.json:
//   { "explode": [ { "name": "Wheels", "parts": ["Wheel*"], "move": "out" },
//                  { "name": "Cargo",  "parts": ["Pile*", "Log*"], "move": "up", "amount": 0.8 },
//                  { "name": "Body",   "parts": ["Deck*", "Rails*"], "move": "stay" } ],
//     "sheath": ["Saya*", "Sageo*"] }
// move: stay | up | down | left | right | front | back | out (each piece away from the middle) | auto (default).
// Parts no group names keep the automatic grouping. "sheath" marks what Unsheath leaves behind.
struct ModelSetup: Decodable {
    struct Group: Decodable {
        var name: String?
        var parts: [String]
        var move: String?
        var amount: Float?
    }
    var explode: [Group]?
    var sheath: [String]?

    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TaruTweaks/ModelViewer")

    static func load(for model: URL) -> ModelSetup? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(model.lastPathComponent + ".json")) else { return nil }
        return try? JSONDecoder().decode(ModelSetup.self, from: data)
    }

    // "Wheel*" style patterns, case doesn't matter
    static func matches(_ name: String, _ patterns: [String]) -> Bool {
        patterns.contains { NSPredicate(format: "SELF LIKE[c] %@", $0).evaluate(with: name) }
    }
}

// Moves a model's parts between poses: together (as the file has it), groups (sensible chunks spaced out),
// apart (every single part spaced out) and drawn (the sword pulled out of its sheath, then laid beside it).
final class ModelPoser {
    enum Pose: String { case together, groups, apart, drawn }
    private enum Move { case auto, stay, out, toward(SIMD3<Float>) }
    private struct Unit { var members: [Int]; var move = Move.auto; var amount: Float = 1 }
    private typealias Box = (low: SIMD3<Float>, high: SIMD3<Float>)

    private let parts: [ModelPart]
    private let fixed: [Bool]                    // skinned meshes follow their bones, so they stay put
    private let chunks: [Unit]
    private var now: [SIMD3<Float>]
    private var layouts: [Pose: [SIMD3<Float>]] = [:]
    private let draw: (to: [SIMD3<Float>], via: [SIMD3<Float>])?
    private(set) var pose = Pose.together

    private var free: [Int] { parts.indices.filter { !fixed[$0] } }
    var canExplode: Bool { free.count > 1 }
    var hasGroups: Bool {
        (chunks.count > 1 && chunks.count < free.count) || chunks.contains { if case .auto = $0.move { return false }; return true }
    }
    var canDraw: Bool { draw != nil }
    var groupCount: Int { chunks.count }

    init(_ parts: [ModelPart], setup: ModelSetup?) {
        self.parts = parts
        fixed = parts.map { $0.node.skinner != nil }
        let named = setup?.sheath
        let sheathed = parts.map { part in named.map { patterns in ModelSetup.matches(part.name, patterns) || part.path.contains { ModelSetup.matches($0, patterns) } } ?? part.sheath }
        now = parts.map { _ in .zero }
        draw = Self.drawn(parts, fixed: fixed, sheathed: sheathed)
        chunks = Self.chunks(parts, fixed: fixed, setup: setup)
    }

    // the pose the Explode button goes to next
    var next: Pose {
        switch pose {
        case .together, .drawn: return hasGroups ? .groups : .apart
        case .groups: return .apart
        case .apart: return .together
        }
    }

    // where a part sits right now (its box moves with it)
    func box(of index: Int) -> (low: SIMD3<Float>, high: SIMD3<Float>) { (parts[index].low + now[index], parts[index].high + now[index]) }

    // MARK: grouping

    private static func box(_ parts: [ModelPart], _ members: [Int], _ offsets: [SIMD3<Float>]? = nil) -> Box {
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in members { low = simd_min(low, parts[i].low + (offsets?[i] ?? .zero)); high = simd_max(high, parts[i].high + (offsets?[i] ?? .zero)) }
        return (low, high)
    }

    // members whose boxes touch (or nearly) end up in the same pile
    private static func piles(_ parts: [ModelPart], _ members: [Int], slack: Float) -> [[Int]] {
        var owner = Dictionary(uniqueKeysWithValues: members.map { ($0, $0) })
        func root(_ i: Int) -> Int { var r = i; while owner[r]! != r { r = owner[r]! }; return r }
        for (n, i) in members.enumerated() {
            for j in members[(n + 1)...] where simd_reduce_min(parts[i].high + slack - parts[j].low) > 0 && simd_reduce_min(parts[j].high + slack - parts[i].low) > 0 { owner[root(i)] = root(j) }
        }
        return Dictionary(grouping: members, by: root).values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    // "Lantern1_Neon" → lantern, "WheelFL_001" → wheel, "Bear_ForeLowerL" → bear_forelower
    static func family(_ name: String) -> String {
        var stem = String(name.prefix { !$0.isNumber })
        while let last = stem.last, "_. -".contains(last) { stem.removeLast() }
        for side in ["FL", "FR", "RL", "RR", "BL", "BR", "L", "R"] where stem.hasSuffix(side) {
            if let before = stem.dropLast(side.count).last, before.isLowercase || before == "_" { stem.removeLast(side.count); break }
        }
        while let last = stem.last, last == "_" { stem.removeLast() }
        return stem.lowercased()
    }

    private static func chunks(_ parts: [ModelPart], fixed: [Bool], setup: ModelSetup?) -> [Unit] {
        var left = parts.indices.filter { !fixed[$0] }
        var units: [Unit] = []
        // 1. what the model's own setup file says
        for group in setup?.explode ?? [] {
            let members = left.filter { i in ModelSetup.matches(parts[i].name, group.parts) || parts[i].path.contains { ModelSetup.matches($0, group.parts) } }
            guard !members.isEmpty else { continue }
            left.removeAll { members.contains($0) }
            let move: Move
            switch group.move?.lowercased() {
            case "stay": move = .stay
            case "out": move = .out
            case "up": move = .toward([0, 1, 0])
            case "down": move = .toward([0, -1, 0])
            case "left": move = .toward([-1, 0, 0])
            case "right": move = .toward([1, 0, 0])
            case "front": move = .toward([0, 0, 1])
            case "back": move = .toward([0, 0, -1])
            default: move = .auto
            }
            units.append(Unit(members: members, move: move, amount: group.amount ?? 1))
        }
        guard !left.isEmpty else { return units }
        // 2. groups the file itself has (a "Katana" holding blade, guard and hilt), when they say anything
        let branches = Dictionary(grouping: left) { parts[$0].branch }
        if branches.count > 1, branches.count < left.count {
            return units + branches.values.map { Unit(members: $0.sorted()) }.sorted { $0.members[0] < $1.members[0] }
        }
        // 3. same name family and touching: a lantern with its glow, a chest with its lid, a stack of logs
        var names = Dictionary(grouping: left) { family(parts[$0].name) }
        for stem in names.keys.sorted(by: { $0.count > $1.count }) {
            // "chestlid" and "brazier_neon" belong with "chest" and "brazier"
            guard let home = names.keys.filter({ $0 != stem && !$0.isEmpty && stem.hasPrefix($0) }).max(by: { $0.count < $1.count }) else { continue }
            names[home]! += names.removeValue(forKey: stem)!
        }
        let whole = box(parts, parts.indices.map { $0 })
        let slack = simd_length(whole.high - whole.low) * 0.005
        return units + names.values.flatMap { piles(parts, $0.sorted(), slack: slack) }.sorted { $0[0] < $1[0] }.map { Unit(members: $0) }
    }

    // MARK: layouts

    private func layout(_ wanted: Pose) -> [SIMD3<Float>] {
        if let known = layouts[wanted] { return known }
        let result: [SIMD3<Float>]
        switch wanted {
        case .together: result = parts.map { _ in .zero }
        case .drawn: result = draw?.to ?? parts.map { _ in .zero }
        case .apart: result = spaced(free.map { Unit(members: [$0]) })
        case .groups: result = spaced(chunks)
        }
        layouts[wanted] = result
        return result
    }

    // set-up groups go where they were told; everything else is pushed out from the middle, then nudged until no two boxes touch
    private func spaced(_ units: [Unit]) -> [SIMD3<Float>] {
        let parts = parts
        let whole = Self.box(parts, parts.indices.map { $0 })
        let middle = (whole.low + whole.high) / 2, size = simd_length(whole.high - whole.low), gap = size * 0.04
        var offsets = parts.map { _ in SIMD3<Float>.zero }

        // told where to go: far enough that way to clear whatever is in its path
        var placed: [[Int]] = []
        func send(_ members: [Int], _ way: SIMD3<Float>, _ amount: Float) {
            let mine = Self.box(parts, members), axis = abs(way.x) > 0.5 ? 0 : (abs(way.y) > 0.5 ? 1 : 2), sign: Float = way[axis] > 0 ? 1 : -1
            var need = size * 0.12
            for i in parts.indices where !members.contains(i) {
                let low = parts[i].low + offsets[i], high = parts[i].high + offsets[i]
                // only things it would actually pass through count
                let inPath = (0..<3).allSatisfy { $0 == axis || (low[$0] < mine.high[$0] && high[$0] > mine.low[$0]) }
                let ahead = sign > 0 ? high[axis] > mine.low[axis] : low[axis] < mine.high[axis]
                if inPath, ahead { need = max(need, sign > 0 ? high[axis] - mine.low[axis] + gap : mine.high[axis] - low[axis] + gap) }
            }
            for i in members { offsets[i][axis] = sign * need * amount }
            placed.append(members)
        }
        var loose: [[Int]] = []
        for unit in units {
            switch unit.move {
            case .auto: loose.append(unit.members)
            case .stay: placed.append(unit.members)
            case .toward(let way): send(unit.members, way, unit.amount)
            case .out:
                // each piece leaves through the side of the model it sits on…
                for pile in Self.piles(parts, unit.members, slack: size * 0.005) {
                    let b = Self.box(parts, pile)
                    // …which is the face of the model's box it is nearest to (a wheel's outer face is the model's side)
                    let centre = (b.low + b.high) / 2, span = simd_max(whole.high - whole.low, SIMD3(repeating: 0.0001))
                    var axis = 0, nearest = Float.greatestFiniteMagnitude
                    for a in 0..<3 {
                        let room = (centre[a] >= middle[a] ? whole.high[a] - b.high[a] : b.low[a] - whole.low[a]) / span[a]
                        if room < nearest - 0.001 { axis = a; nearest = room }
                    }
                    var way = SIMD3<Float>.zero
                    way[axis] = centre[axis] >= middle[axis] ? 1 : -1
                    send(pile, way, unit.amount)
                }
            }
        }
        guard !loose.isEmpty else { return offsets }

        // the rest: spread from the middle by the smallest amount that untangles as much as spreading ever will…
        let boxes = loose.map { Self.box(parts, $0) }, still = placed.map { Self.box(parts, $0, offsets) }
        func spread(_ by: Float) -> [SIMD3<Float>] { boxes.map { (($0.low + $0.high) / 2 - middle) * by } }
        func clash(_ a: Box, _ b: Box) -> (up: SIMD3<Float>, down: SIMD3<Float>)? {
            let up = b.high + gap - a.low, down = a.high + gap - b.low
            return simd_reduce_min(up) > 0 && simd_reduce_min(down) > 0 ? (up, down) : nil
        }
        func moved(_ i: Int, _ shift: [SIMD3<Float>]) -> Box { (boxes[i].low + shift[i], boxes[i].high + shift[i]) }
        func clashes(_ shift: [SIMD3<Float>]) -> Int {
            boxes.indices.reduce(0) { n, i in n + boxes.indices.filter { $0 > i && clash(moved(i, shift), moved($0, shift)) != nil }.count }
        }
        func nearest(_ c: (up: SIMD3<Float>, down: SIMD3<Float>)) -> (axis: Int, amount: Float) {
            var axis = 0, amount = Float.greatestFiniteMagnitude
            for a in 0..<3 { for candidate in [c.up[a], -c.down[a]] where abs(candidate) < abs(amount) { axis = a; amount = candidate } }
            return (axis, amount)
        }
        let floor = clashes(spread(1.5))
        var shift = spread(stride(from: Float(0.3), through: 1.5, by: 0.1).first { clashes(spread($0)) <= floor } ?? 1.5)
        // …then slide what still overlaps apart the shortest way (parts that sit inside each other never untangle by spreading)
        for _ in 0..<400 {
            var touched = false
            for i in boxes.indices {
                for j in boxes.indices where j > i {
                    guard let c = clash(moved(i, shift), moved(j, shift)) else { continue }
                    let (axis, amount) = nearest(c)
                    shift[i][axis] += amount * 0.5; shift[j][axis] -= amount * 0.5
                    touched = true
                }
                for wall in still {
                    guard let c = clash(moved(i, shift), wall) else { continue }
                    let (axis, amount) = nearest(c)
                    shift[i][axis] += amount
                    touched = true
                }
            }
            if !touched { break }
        }
        for (members, by) in zip(loose, shift) { for i in members { offsets[i] = by } }
        return offsets
    }

    // a sheath with something inside it: the rest slides out along the sheath's length, then settles above it
    private static func drawn(_ parts: [ModelPart], fixed: [Bool], sheathed: [Bool]) -> (to: [SIMD3<Float>], via: [SIMD3<Float>])? {
        let sheath = parts.indices.filter { sheathed[$0] && !fixed[$0] }, sword = parts.indices.filter { !sheathed[$0] && !fixed[$0] }
        guard !sheath.isEmpty, !sword.isEmpty, !fixed.contains(true) else { return nil }
        // the sheath itself is its biggest piece; cords and fittings just ride along
        guard let body = sheath.max(by: { simd_length(parts[$0].high - parts[$0].low) < simd_length(parts[$1].high - parts[$1].low) }) else { return nil }
        let size = parts[body].high - parts[body].low
        let along = size.x >= size.y && size.x >= size.z ? 0 : (size.y >= size.z ? 1 : 2)
        let lift = along == 1 ? 2 : 1
        let swordBox = box(parts, sword), sheathBox = box(parts, sheath)
        // "inside" = shares most of the sheath's length, and the blade's own line runs through the sheath, not beside it
        let shared = min(swordBox.high[along], parts[body].high[along]) - max(swordBox.low[along], parts[body].low[along])
        guard shared > size[along] * 0.5 else { return nil }
        guard let blade = sword.max(by: { (parts[$0].high - parts[$0].low)[along] < (parts[$1].high - parts[$1].low)[along] }) else { return nil }
        for a in 0..<3 where a != along {
            let mid = (parts[blade].low[a] + parts[blade].high[a]) / 2
            guard mid > parts[body].low[a], mid < parts[body].high[a] else { return nil }
        }
        // pull toward the hilt end: the side where the sword sticks out of the sheath
        let toward: Float = (swordBox.low[along] + swordBox.high[along]) < (parts[body].low[along] + parts[body].high[along]) ? -1 : 1
        let pull = toward < 0 ? swordBox.high[along] - parts[body].low[along] : parts[body].high[along] - swordBox.low[along]
        var out = SIMD3<Float>.zero, rest = SIMD3<Float>.zero
        out[along] = toward * pull * 1.04
        rest[lift] = sheathBox.high[lift] - swordBox.low[lift] + simd_length(size) * 0.04
        return (parts.indices.map { sheathed[$0] ? .zero : rest }, parts.indices.map { sheathed[$0] ? .zero : out })
    }

    // MARK: moving

    func go(_ wanted: Pose, on canvas: ModelCanvas, animated: Bool = true) {
        guard wanted != pose, wanted != .drawn || draw != nil else { return }
        let from = now, to = layout(wanted)
        // drawing and sheathing go by way of "pulled straight out"
        var via: [SIMD3<Float>]?, split: Float = 0.5
        if pose == .together, wanted == .drawn { via = draw!.via; split = 0.6 }
        if pose == .drawn, wanted == .together { via = draw!.via; split = 0.4 }
        let opening = wanted != .together
        pose = wanted

        let parts = parts, fixed = fixed
        let everything = parts.indices.map { $0 }
        let end = Self.box(parts, everything, to)
        var travel = end
        for stop in [from, via ?? to] { let b = Self.box(parts, everything, stop); travel = (simd_min(travel.low, b.low), simd_max(travel.high, b.high)) }
        func place(_ offsets: [SIMD3<Float>]) {
            now = offsets
            for (i, part) in parts.enumerated() where !fixed[i] { part.node.simdWorldPosition = part.home + offsets[i] }
        }
        guard animated else { place(to); canvas.refit(low: end.low, high: end.high, animated: false, seconds: 0); return }

        // furthest travellers leave first, the rest follow within a fifth of a second
        let reach = parts.indices.map { simd_length(to[$0] - from[$0]) }, longest = max(reach.max() ?? 0, 0.0001)
        let move = via == nil ? 0.7 : 1.25, stagger = via == nil ? 0.2 : 0.0, total = move + stagger
        func ease(_ t: Float) -> Float { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
        func spring(_ t: Float) -> Float { 1 + 2.2 * pow(t - 1, 3) + 1.2 * pow(t - 1, 2) }
        canvas.refit(low: travel.low, high: travel.high, animated: true, seconds: 0.5)
        canvas.run("parts", seconds: total, tick: { clock in
            var offsets = from
            for i in parts.indices where !fixed[i] {
                let wait = Float(stagger) * (1 - reach[i] / longest)
                let t = min(max((clock * Float(total) - wait) / Float(move), 0), 1)
                if let via {
                    offsets[i] = t < split ? from[i] + (via[i] - from[i]) * ease(t / split) : via[i] + (to[i] - via[i]) * ease((t - split) / (1 - split))
                } else {
                    offsets[i] = from[i] + (to[i] - from[i]) * (opening ? spring(t) : ease(t))
                }
            }
            place(offsets)
        }, done: {
            if simd_length(travel.low - end.low) + simd_length(travel.high - end.high) > 0.0001 { canvas.refit(low: end.low, high: end.high, animated: true, seconds: 0.45) }
        })
    }
}
