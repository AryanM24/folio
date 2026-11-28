import Foundation

// Every timeline edit, as a pure `mutating` function on `Project`.
//
// Rules every operation follows:
// - Times are snapped to the project's frame grid first, so results are frame-exact.
// - Gesture-style edits (trim, roll, slip, slide) clamp to what's possible (a frame minimum,
//   the media's length, the neighbours) and return the delta actually applied.
// - Invalid targets (missing clip, locked track, wrong kind of track) throw `EditError`.
//   Call through `ProjectStore.edit`, which works on a copy, so a throw changes nothing.
// - Ripple edits (anything that adds or removes time) also apply to every other unlocked
//   sync-locked track, and move markers, whenever the edited track is sync-locked.
// - Trims, rolls, slips and slides act on the one clip; moves, deletes, copies and splits
//   act on its whole group.

nonisolated enum TrimEdge: String, Codable, Sendable { case start, end }

nonisolated enum PlacementMode: String, Codable, Sendable {
    /// Push later clips along to make room.
    case insert
    /// Replace whatever is there.
    case overwrite
}

nonisolated enum EditError: LocalizedError, Equatable, Sendable {
    case clipNotFound
    case trackNotFound
    case sourceNotFound
    case trackLocked(String)
    case wrongTrack(String)
    case noAdjacentClip
    case notMedia
    case noSound
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .clipNotFound: "That clip isn't in the project any more."
        case .trackNotFound: "That track isn't in the project any more."
        case .sourceNotFound: "The media for this clip isn't in the project."
        case .trackLocked(let name): "Track \(name) is locked. Unlock it to edit."
        case .wrongTrack(let name): "That kind of clip can't go on track \(name)."
        case .noAdjacentClip: "There's no clip right next to this one."
        case .notMedia: "Only video and audio clips can do that."
        case .noSound: "This clip has no sound."
        case .invalid(let message): message
        }
    }
}

/// Fresh group IDs for the right-hand pieces of one edit, so pieces cut at the same point
/// stay linked to each other but not to the left-hand pieces.
nonisolated struct Regroup {
    private var map: [GroupID: GroupID] = [:]

    subscript(_ group: GroupID?) -> GroupID? {
        mutating get {
            guard let group else { return nil }
            if let fresh = map[group] { return fresh }
            let fresh = GroupID()
            map[group] = fresh
            return fresh
        }
    }
}

/// Clips copied for paste or duplicate. Codable so it can go on the pasteboard.
nonisolated struct ClipBundle: Codable, Equatable, Sendable {
    static let pasteboardType = "app.folio.video-clips"

    struct Item: Codable, Equatable, Sendable {
        /// Tracks below the topmost copied track (0 = the paste target).
        var trackOffset: Int
        var trackKind: Track.Kind
        /// `start` is relative to the bundle's start.
        var clip: Clip
    }

    var items: [Item]
    /// The media and transcripts the clips need, so pasting into another project works.
    var sources: [MediaSource]
    var transcripts: [Transcript]
    var duration: Time
}

/// Which attributes Paste Attributes copies.
nonisolated struct ClipAttributes: OptionSet, Sendable {
    let rawValue: Int
    static let transform = ClipAttributes(rawValue: 1 << 0)
    static let effects = ClipAttributes(rawValue: 1 << 1)
    static let audio = ClipAttributes(rawValue: 1 << 2)
    static let transitions = ClipAttributes(rawValue: 1 << 3)
    static let all: ClipAttributes = [.transform, .effects, .audio, .transitions]
}

// MARK: - Track primitives

nonisolated extension Track {
    var end: Time { clips.last?.end ?? .zero }

    func index(of id: ClipID) -> Int? { clips.firstIndex { $0.id == id } }
    func isEmpty(in range: TimeRange) -> Bool { !clips.contains { $0.range.overlaps(range) } }

    /// Empty stretches between zero and the last clip.
    var gaps: [TimeRange] {
        var cursor = Time.zero
        var result: [TimeRange] = []
        for clip in clips {
            if clip.start > cursor { result.append(TimeRange(start: cursor, end: clip.start)) }
            cursor = max(cursor, clip.end)
        }
        return result
    }

    /// Inserts in start order. The caller makes sure there's room.
    mutating func place(_ clip: Clip) {
        clips.insert(clip, at: clips.firstIndex { $0.start > clip.start } ?? clips.endIndex)
    }

    /// Cuts the clip under `time` in two; the right piece gets a new ID.
    @discardableResult
    mutating func split(at time: Time, regroup: inout Regroup) -> ClipID? {
        guard let i = clips.firstIndex(where: { $0.start < time && time < $0.end }) else { return nil }
        return split(clipAt: i, at: time, regroup: &regroup)
    }

    /// Cuts clip `i` at `time`, which must be strictly inside it.
    mutating func split(clipAt i: Int, at time: Time, regroup: inout Regroup) -> ClipID {
        let clip = clips[i]
        var right = clip.reframed(to: TimeRange(start: time, end: clip.end))
        right.id = ClipID()
        right.groupID = regroup[clip.groupID]
        clips[i] = clip.reframed(to: TimeRange(start: clip.start, end: time))
        clips.insert(right, at: i + 1)
        return right.id
    }

    /// Removes everything inside `range`, leaving a gap. Clips crossing an edge are cut.
    mutating func clear(_ range: TimeRange, regroup: inout Regroup) {
        split(at: range.start, regroup: &regroup)
        split(at: range.end, regroup: &regroup)
        clips.removeAll { range.start <= $0.start && $0.end <= range.end }
    }

    mutating func shift(from time: Time, by delta: Time) {
        for i in clips.indices where clips[i].start >= time { clips[i].start += delta }
    }

    mutating func removeTime(_ range: TimeRange, regroup: inout Regroup) {
        clear(range, regroup: &regroup)
        shift(from: range.end, by: -range.duration)
    }

    mutating func insertTime(at time: Time, _ length: Time, regroup: inout Regroup) {
        split(at: time, regroup: &regroup)
        shift(from: time, by: length)
    }
}

// MARK: - Edits

nonisolated extension Project {
    func snap(_ time: Time) -> Time { settings.frameRate.snap(time) }

    /// `ids` plus every clip grouped with one of them.
    func expandingGroups(_ ids: Set<ClipID>) -> Set<ClipID> {
        let groups = Set(tracks.flatMap(\.clips).filter { ids.contains($0.id) }.compactMap(\.groupID))
        return ids.union(tracks.flatMap(\.clips).filter { $0.groupID.map(groups.contains) ?? false }.map(\.id))
    }

    /// How far an edge can be pulled out before the media runs out, in whole timeline
    /// frames; `nil` when there's no limit (stills, holds, unknown length).
    func room(_ clip: Clip, _ edge: TrimEdge) -> Time? {
        guard clip.content.usesSourceTime, let id = clip.sourceID, let length = source(id)?.duration else { return nil }
        let speed = edge == .start ? clip.retime.speed(at: .zero) : clip.retime.speed(at: clip.duration)
        guard speed > .zero else { return nil }
        let before = clip.sourceStart, after = length - clip.sourceRange.end
        let available = (edge == .start) != clip.retime.reversed ? before : after
        return max(.zero, settings.frameRate.floor(available / speed))
    }

    // MARK: Split

    /// Blade: splits every clip under `time` on `tracks` (default: every unlocked track).
    /// Returns the new right-hand clips.
    @discardableResult
    mutating func split(at time: Time, tracks ids: Set<TrackID>? = nil) throws -> [ClipID] {
        let t = snap(time)
        var regroup = Regroup()
        var made: [ClipID] = []
        for i in tracks.indices where ids?.contains(tracks[i].id) ?? !tracks[i].isLocked {
            try requireUnlocked(i)
            if let id = tracks[i].split(at: t, regroup: &regroup) { made.append(id) }
        }
        return made
    }

    /// Splits one clip (and the clips grouped with it) at `time`.
    @discardableResult
    mutating func split(_ id: ClipID, at time: Time) throws -> [ClipID] {
        guard let clip = clip(id) else { throw EditError.clipNotFound }
        let t = snap(time)
        guard clip.start < t, t < clip.end else { throw EditError.invalid("The playhead isn't inside this clip.") }
        var regroup = Regroup()
        var made: [ClipID] = []
        for member in expandingGroups([id]) {
            guard let (ti, ci) = location(of: member) else { continue }
            try requireUnlocked(ti)
            let c = tracks[ti].clips[ci]
            if c.start < t, t < c.end { made.append(tracks[ti].split(clipAt: ci, at: t, regroup: &regroup)) }
        }
        return made
    }

    // MARK: Trim, roll, slip, slide

    /// Moves one edge of a clip to `time`. Without ripple the clip can't cross its
    /// neighbours; with ripple the clip's start stays put and everything after it moves.
    @discardableResult
    mutating func trim(_ id: ClipID, edge: TrimEdge, to time: Time, ripple: Bool = false) throws -> Time {
        guard let (t, i) = location(of: id) else { throw EditError.clipNotFound }
        try requireUnlocked(t)
        let clip = tracks[t].clips[i]
        let frame = frameDuration
        var delta = snap(time) - (edge == .start ? clip.start : clip.end)
        switch edge {
        case .start:
            delta = min(delta, clip.duration - frame)
            if let room = room(clip, .start) { delta = max(delta, -room) }
            if !ripple { delta = max(delta, (i > 0 ? tracks[t].clips[i - 1].end : .zero) - clip.start) }
        case .end:
            delta = max(delta, frame - clip.duration)
            if let room = room(clip, .end) { delta = min(delta, room) }
            if !ripple, i + 1 < tracks[t].clips.count { delta = min(delta, tracks[t].clips[i + 1].start - clip.end) }
        }
        guard delta != .zero else { return .zero }
        let window =
            edge == .start
            ? TimeRange(start: clip.start + delta, end: clip.end) : TimeRange(start: clip.start, end: clip.end + delta)
        var trimmed = clip.reframed(to: window, keepEdges: true)
        if ripple {
            trimmed.start = clip.start
            replaceRippling(track: t, index: i, with: trimmed, at: edge == .start ? clip.start : min(clip.end, trimmed.end))
        } else {
            tracks[t].clips[i] = trimmed
        }
        return delta
    }

    /// Moves the edit point after `leftID` by `delta`: the left clip's end and the next
    /// clip's start move together, so nothing else moves.
    @discardableResult
    mutating func roll(_ leftID: ClipID, by delta: Time) throws -> Time {
        guard let (t, i) = location(of: leftID) else { throw EditError.clipNotFound }
        try requireUnlocked(t)
        guard i + 1 < tracks[t].clips.count, tracks[t].clips[i + 1].start == tracks[t].clips[i].end else {
            throw EditError.noAdjacentClip
        }
        let left = tracks[t].clips[i], right = tracks[t].clips[i + 1]
        var d = snap(delta)
        d = min(d, right.duration - frameDuration)
        d = max(d, frameDuration - left.duration)
        if let room = room(left, .end) { d = min(d, room) }
        if let room = room(right, .start) { d = max(d, -room) }
        guard d != .zero else { return .zero }
        tracks[t].clips[i] = left.reframed(to: TimeRange(start: left.start, end: left.end + d), keepEdges: true)
        tracks[t].clips[i + 1] = right.reframed(to: TimeRange(start: right.start + d, end: right.end), keepEdges: true)
        return d
    }

    /// Shows a different part of the media in the same place: the source window moves by
    /// `delta` (source time), the clip stays.
    @discardableResult
    mutating func slip(_ id: ClipID, by delta: Time) throws -> Time {
        guard let (t, i) = location(of: id) else { throw EditError.clipNotFound }
        try requireUnlocked(t)
        let clip = tracks[t].clips[i]
        guard clip.content.usesSourceTime, let sourceID = clip.sourceID else { throw EditError.notMedia }
        var start = max(.zero, clip.sourceStart + delta)
        if let length = source(sourceID)?.duration { start = min(start, max(.zero, length - clip.sourceDuration)) }
        tracks[t].clips[i].sourceStart = start
        return start - clip.sourceStart
    }

    /// Moves a clip between its neighbours: butted neighbours grow and shrink to match, so
    /// the track's length doesn't change.
    @discardableResult
    mutating func slide(_ id: ClipID, by delta: Time) throws -> Time {
        guard let (t, i) = location(of: id) else { throw EditError.clipNotFound }
        try requireUnlocked(t)
        let clips = tracks[t].clips, clip = clips[i], frame = frameDuration
        let prev = i > 0 ? clips[i - 1] : nil, next = i + 1 < clips.count ? clips[i + 1] : nil
        let prevButted = prev?.end == clip.start, nextButted = next?.start == clip.end
        var d = snap(delta)
        if let prev, prevButted {
            d = max(d, frame - prev.duration)
            if let room = room(prev, .end) { d = min(d, room) }
        } else {
            d = max(d, (prev?.end ?? .zero) - clip.start)
        }
        if let next, nextButted {
            d = min(d, next.duration - frame)
            if let room = room(next, .start) { d = max(d, -room) }
        } else if let next {
            d = min(d, next.start - clip.end)
        }
        guard d != .zero else { return .zero }
        if let prev, prevButted {
            tracks[t].clips[i - 1] = prev.reframed(to: TimeRange(start: prev.start, end: prev.end + d), keepEdges: true)
        }
        if let next, nextButted {
            tracks[t].clips[i + 1] = next.reframed(to: TimeRange(start: next.start + d, end: next.end), keepEdges: true)
        }
        tracks[t].clips[i].start += d
        return d
    }

    // MARK: Delete

    /// Delete, leaving a gap.
    mutating func lift(clips ids: Set<ClipID>) throws {
        let all = expandingGroups(ids)
        let hit = tracks.indices.filter { t in tracks[t].clips.contains { all.contains($0.id) } }
        guard !hit.isEmpty else { throw EditError.clipNotFound }
        for t in hit { try requireUnlocked(t) }
        for t in hit { tracks[t].clips.removeAll { all.contains($0.id) } }
    }

    /// Delete and close the gap. Only time left empty on every track the clips were on is
    /// removed, so no unselected clip on those tracks is cut; sync-locked tracks follow.
    mutating func rippleDelete(clips ids: Set<ClipID>) throws {
        let all = expandingGroups(ids)
        var ranges: [TimeRange] = []
        var targets = Set<Int>()
        for (t, track) in tracks.enumerated() {
            for clip in track.clips where all.contains(clip.id) {
                ranges.append(clip.range)
                targets.insert(t)
            }
        }
        try lift(clips: all)
        let removable = merged(ranges).flatMap { emptyParts(of: $0, on: targets) }
        removeTime(removable, rippling: targets)
    }

    /// Avid-style lift: clears `range` on `tracks`, leaving a gap.
    mutating func lift(range: TimeRange, tracks ids: Set<TrackID>) throws {
        let r = TimeRange(start: snap(range.start), end: snap(range.end))
        guard !r.isEmpty else { return }
        var regroup = Regroup()
        for t in try unlockedIndices(ids) { tracks[t].clear(r, regroup: &regroup) }
    }

    /// Avid-style extract: removes `range` from `tracks` and closes it up.
    mutating func extract(range: TimeRange, tracks ids: Set<TrackID>) throws {
        let r = TimeRange(start: snap(range.start), end: snap(range.end))
        guard !r.isEmpty else { return }
        removeTime([r], rippling: Set(try unlockedIndices(ids)))
    }

    /// Text-based editing: removes the timeline ranges of deleted words (from
    /// `timelineWords()`, one range per contiguous selection). Each range shrinks by
    /// `padding` at both ends, so neighbouring words keep their consonants, and snaps
    /// inwards to whole frames.
    mutating func cut(wordRanges: [TimeRange], padding: Time = Time(value: 1, timescale: 25)) throws {
        let rate = settings.frameRate
        let ranges = wordRanges.compactMap { r -> TimeRange? in
            let shrunk = TimeRange(start: rate.ceil(r.start + padding), end: rate.floor(r.end - padding))
            return shrunk.isEmpty ? nil : shrunk
        }
        let cuts = merged(ranges)
        guard !cuts.isEmpty else { return }
        let targets = Set(
            tracks.indices.filter { t in
                tracks[t].clips.contains { clip in clip.content.usesSourceTime && cuts.contains { $0.overlaps(clip.range) } }
            })
        for t in targets { try requireUnlocked(t) }
        removeTime(cuts, rippling: targets)
    }

    /// Removes the gaps on a track, but only where every track that would ripple with it is
    /// empty too, so closing gaps never cuts anything.
    mutating func closeGaps(in id: TrackID) throws {
        guard let t = trackIndex(id) else { throw EditError.trackNotFound }
        try requireUnlocked(t)
        let (all, _) = rippleSet([t])
        removeTime(tracks[t].gaps.flatMap { emptyParts(of: $0, on: Set(all)) }, rippling: [t])
    }

    // MARK: Place

    /// Inserts `clips` end to end at `time`, pushing later clips along.
    @discardableResult
    mutating func insert(_ clips: [Clip], at time: Time, track id: TrackID) throws -> [ClipID] {
        let (t, laid) = try layOut(clips, at: time, on: id)
        guard let last = laid.last else { return [] }
        var regroup = Regroup()
        let (all, movesMarkers) = rippleSet([t])
        insertTime(at: laid[0].start, last.end - laid[0].start, tracks: all, movesMarkers: movesMarkers, regroup: &regroup)
        for clip in laid { tracks[t].place(clip) }
        return laid.map(\.id)
    }

    /// Puts `clips` end to end at `time`, replacing what's there.
    @discardableResult
    mutating func overwrite(_ clips: [Clip], at time: Time, track id: TrackID) throws -> [ClipID] {
        let (t, laid) = try layOut(clips, at: time, on: id)
        guard let last = laid.last else { return [] }
        var regroup = Regroup()
        tracks[t].clear(TimeRange(start: laid[0].start, end: last.end), regroup: &regroup)
        for clip in laid { tracks[t].place(clip) }
        return laid.map(\.id)
    }

    /// Adds `clips` after the last clip on the track.
    @discardableResult
    mutating func append(_ clips: [Clip], track id: TrackID) throws -> [ClipID] {
        guard let t = trackIndex(id) else { throw EditError.trackNotFound }
        return try overwrite(clips, at: tracks[t].end, track: id)
    }

    /// Drags clips (and their groups) by `offset` and `trackOffset` tracks. Overwrite drops
    /// them on top of whatever is there; insert closes the space they left and opens room
    /// at the drop point, on the clips' own tracks only (a reorder).
    mutating func move(_ ids: Set<ClipID>, by offset: Time, trackOffset: Int = 0, mode: PlacementMode = .overwrite) throws {
        let all = expandingGroups(ids)
        var moving: [(from: Int, clip: Clip)] = []
        for (t, track) in tracks.enumerated() {
            for clip in track.clips where all.contains(clip.id) { moving.append((t, clip)) }
        }
        guard !moving.isEmpty else { throw EditError.clipNotFound }
        for m in moving {
            let dest = m.from + trackOffset
            guard tracks.indices.contains(dest) else { throw EditError.trackNotFound }
            try requireUnlocked(m.from)
            try requireUnlocked(dest)
            guard tracks[dest].accepts(m.clip.content, source: m.clip.sourceID.flatMap(source)) else {
                throw EditError.wrongTrack(tracks[dest].name)
            }
        }
        let blockStart = moving.map { $0.clip.start }.min() ?? .zero
        let blockEnd = moving.map { $0.clip.end }.max() ?? .zero
        let delta = max(snap(offset), -blockStart)
        var regroup = Regroup()
        for t in Set(moving.map { $0.from }) { tracks[t].clips.removeAll { all.contains($0.id) } }
        switch mode {
        case .overwrite:
            for m in moving {
                var clip = m.clip
                clip.start += delta
                tracks[m.from + trackOffset].clear(clip.range, regroup: &regroup)
                tracks[m.from + trackOffset].place(clip)
            }
        case .insert:
            let drop = blockStart + delta
            var removedBefore: [Int: Time] = [:]
            for (t, group) in Dictionary(grouping: moving, by: { $0.from }) {
                let ranges = group.map { $0.clip.range }
                for r in merged(ranges).reversed() { tracks[t].removeTime(r, regroup: &regroup) }
                // Where the drop point lands once the clips' old places have closed up.
                removedBefore[t] = merged(ranges).reduce(Time.zero) { $0 + (min(drop, $1.end) - min(drop, $1.start)) }
            }
            for dest in Set(moving.map { $0.from + trackOffset }) {
                let at = drop - (removedBefore[dest] ?? .zero)
                tracks[dest].insertTime(at: at, blockEnd - blockStart, regroup: &regroup)
                for m in moving where m.from + trackOffset == dest {
                    var clip = m.clip
                    clip.start = at + (clip.start - blockStart)
                    tracks[dest].place(clip)
                }
            }
        }
    }

    // MARK: Copy, paste, duplicate, group

    /// The clips (with their groups) for the pasteboard, or `nil` if none exist.
    func copy(_ ids: Set<ClipID>) -> ClipBundle? {
        let all = expandingGroups(ids)
        let picked = tracks.enumerated().flatMap { t, track in track.clips.filter { all.contains($0.id) }.map { (t, track.kind, $0) } }
        guard let top = picked.map({ $0.0 }).min(), let start = picked.map({ $0.2.start }).min(),
            let end = picked.map({ $0.2.end }).max()
        else { return nil }
        let items = picked.map { t, kind, clip in
            var relative = clip
            relative.start = clip.start - start
            return ClipBundle.Item(trackOffset: t - top, trackKind: kind, clip: relative)
        }
        let used = Set(items.compactMap(\.clip.sourceID))
        return ClipBundle(
            items: items, sources: sources.filter { used.contains($0.id) },
            transcripts: transcripts.filter { used.contains($0.sourceID) }, duration: end - start)
    }

    /// Pastes a bundle at `time` with its top track on `track`. Missing tracks are added;
    /// media the project doesn't have yet comes along. Clips get new IDs and groups.
    @discardableResult
    mutating func paste(_ bundle: ClipBundle, at time: Time, track id: TrackID, mode: PlacementMode = .insert) throws -> [ClipID] {
        guard let anchor = trackIndex(id) else { throw EditError.trackNotFound }
        for source in bundle.sources where self.source(source.id) == nil { sources.append(source) }
        for transcript in bundle.transcripts where self.transcript(for: transcript.sourceID) == nil { transcripts.append(transcript) }
        let at = snap(time)
        // Separate maps: the pasted clips' new groups must never be shared with pieces of
        // existing clips cut to make room.
        var newGroups = Regroup()
        var regroup = Regroup()
        var placed: [(track: Int, clip: Clip)] = []
        for item in bundle.items {
            while anchor + item.trackOffset >= tracks.count { addTrack(item.trackKind) }
            let t = anchor + item.trackOffset
            try requireUnlocked(t)
            guard tracks[t].accepts(item.clip.content, source: item.clip.sourceID.flatMap(source)) else {
                throw EditError.wrongTrack(tracks[t].name)
            }
            var clip = item.clip
            clip.id = ClipID()
            clip.groupID = newGroups[clip.groupID]
            // Snapped, in case the bundle came from a project with another frame rate.
            clip.start = at + snap(clip.start)
            clip.duration = max(frameDuration, snap(clip.duration))
            placed.append((t, clip))
        }
        let targets = Set(placed.map { $0.track })
        switch mode {
        case .insert:
            let (all, movesMarkers) = rippleSet(targets)
            insertTime(at: at, snap(bundle.duration), tracks: all, movesMarkers: movesMarkers, regroup: &regroup)
        case .overwrite:
            for p in placed { tracks[p.track].clear(p.clip.range, regroup: &regroup) }
        }
        for p in placed { tracks[p.track].place(p.clip) }
        return placed.map { $0.clip.id }
    }

    /// Copies the clips (and their groups) and inserts the copy right after them.
    @discardableResult
    mutating func duplicate(_ ids: Set<ClipID>) throws -> [ClipID] {
        let all = expandingGroups(ids)
        guard let bundle = copy(all), let top = tracks.indices.first(where: { t in tracks[t].clips.contains { all.contains($0.id) } }),
            let end = tracks.flatMap(\.clips).filter({ all.contains($0.id) }).map(\.end).max()
        else { throw EditError.clipNotFound }
        return try paste(bundle, at: end, track: tracks[top].id, mode: .insert)
    }

    /// Links clips so they move, delete and copy together. Merges any groups they were in.
    @discardableResult
    mutating func group(_ ids: Set<ClipID>) throws -> GroupID {
        let all = expandingGroups(ids)
        guard all.count >= 2 else { throw EditError.invalid("Select two or more clips to group.") }
        let group = GroupID()
        for t in tracks.indices {
            for i in tracks[t].clips.indices where all.contains(tracks[t].clips[i].id) { tracks[t].clips[i].groupID = group }
        }
        return group
    }

    /// Unlinks the clips' groups entirely.
    mutating func ungroup(_ ids: Set<ClipID>) {
        let all = expandingGroups(ids)
        for t in tracks.indices {
            for i in tracks[t].clips.indices where all.contains(tracks[t].clips[i].id) { tracks[t].clips[i].groupID = nil }
        }
    }

    /// Copies look, sound or transitions from `source` onto other clips.
    mutating func pasteAttributes(from source: Clip, to ids: Set<ClipID>, _ attributes: ClipAttributes) throws {
        for id in ids {
            guard let (t, i) = location(of: id) else { throw EditError.clipNotFound }
            try requireUnlocked(t)
            if attributes.contains(.transform) { tracks[t].clips[i].transform = source.transform }
            if attributes.contains(.effects) {
                tracks[t].clips[i].effects = source.effects.map {
                    var e = $0; e.id = EffectID(); return e
                }
            }
            if attributes.contains(.audio) { tracks[t].clips[i].audio = source.audio }
            if attributes.contains(.transitions) {
                tracks[t].clips[i].transitionIn = source.transitionIn
                tracks[t].clips[i].transitionOut = source.transitionOut
            }
        }
    }

    // MARK: Time effects

    /// Changes how a clip walks through its media, keeping the same footage: the clip gets
    /// longer or shorter and later clips ripple.
    mutating func retime(_ id: ClipID, _ retime: Retime) throws {
        guard let (t, i) = location(of: id) else { throw EditError.clipNotFound }
        try requireUnlocked(t)
        let clip = tracks[t].clips[i]
        guard clip.content.usesSourceTime else { throw EditError.notMedia }
        guard let length = retime.timelineOffset(forSource: clip.sourceDuration) else {
            throw EditError.invalid("A clip can't end on a hold.")
        }
        var changed = clip
        changed.retime = retime
        changed.duration = max(frameDuration, snap(length))
        // Rounding to whole frames must not run past the media.
        if let id = clip.sourceID, let total = source(id)?.duration, changed.sourceRange.end > total {
            changed.duration = max(frameDuration, settings.frameRate.floor(length))
        }
        replaceRippling(track: t, index: i, with: changed, at: min(clip.end, changed.end))
    }

    /// Constant speed (2 is twice as fast). Ripples.
    mutating func setSpeed(_ id: ClipID, _ speed: Rational) throws {
        guard speed > .zero else { throw EditError.invalid("Speed must be above zero. Use a freeze frame to hold.") }
        guard let clip = clip(id) else { throw EditError.clipNotFound }
        var r = clip.retime
        r.segments = Retime(speed: speed).segments
        try retime(id, r)
    }

    mutating func setReversed(_ id: ClipID, _ reversed: Bool) throws {
        guard let (t, i) = location(of: id) else { throw EditError.clipNotFound }
        try requireUnlocked(t)
        guard tracks[t].clips[i].content.usesSourceTime else { throw EditError.notMedia }
        tracks[t].clips[i].retime.reversed = reversed
    }

    /// Holds the frame at `time` for `duration`, pushing the rest of the clip along.
    @discardableResult
    mutating func freezeFrame(at time: Time, track id: TrackID, duration: Time) throws -> ClipID {
        guard let t = trackIndex(id) else { throw EditError.trackNotFound }
        try requireUnlocked(t)
        let at = snap(time)
        guard let clip = tracks[t].clips.first(where: { $0.range.contains(at) }) else {
            throw EditError.invalid("There's no clip under the playhead.")
        }
        guard clip.content.usesSourceTime, let sourceID = clip.sourceID, let frame = clip.sourceTime(atOffset: at - clip.start),
            source(sourceID)?.kind == .video
        else { throw EditError.notMedia }
        var freeze = Clip(content: .freeze(source: sourceID, at: frame), start: at, duration: max(frameDuration, snap(duration)))
        freeze.transform = clip.transform
        freeze.effects = clip.effects
        freeze.audio.isEnabled = false
        var regroup = Regroup()
        let (all, movesMarkers) = rippleSet([t])
        insertTime(at: at, freeze.duration, tracks: all, movesMarkers: movesMarkers, regroup: &regroup)
        tracks[t].place(freeze)
        return freeze.id
    }

    /// Moves a video clip's sound onto an audio track as its own clip, linked to the video.
    @discardableResult
    mutating func detachAudio(_ id: ClipID) throws -> ClipID {
        guard let (t, i) = location(of: id) else { throw EditError.clipNotFound }
        try requireUnlocked(t)
        let clip = tracks[t].clips[i]
        guard tracks[t].kind.isVisual, clip.content.usesSourceTime else { throw EditError.notMedia }
        guard clip.audio.isEnabled, let sourceID = clip.sourceID, source(sourceID)?.hasAudio == true else { throw EditError.noSound }
        let group = clip.groupID ?? GroupID()
        var sound = clip
        sound.id = ClipID()
        sound.groupID = group
        sound.transform = Transform()
        sound.effects = []
        tracks[t].clips[i].groupID = group
        tracks[t].clips[i].audio.isEnabled = false
        if let lane = tracks.indices.first(where: {
            tracks[$0].kind == .audio && !tracks[$0].isLocked && tracks[$0].isEmpty(in: clip.range)
        }) {
            tracks[lane].place(sound)
        } else {
            addTrack(.audio)
            tracks[tracks.count - 1].place(sound)
        }
        return sound.id
    }

    // MARK: Transitions

    /// The longest transition that fits at `edge`: half of it plays over each side's handles.
    func maxTransitionDuration(_ id: ClipID, edge: TrimEdge) -> Time {
        guard let (t, i) = location(of: id) else { return .zero }
        let clips = tracks[t].clips, clip = clips[i]
        let neighbour = edge == .start ? (i > 0 ? clips[i - 1] : nil) : (i + 1 < clips.count ? clips[i + 1] : nil)
        guard let neighbour, edge == .start ? neighbour.end == clip.start : neighbour.start == clip.end else { return clip.duration }
        let mine = room(clip, edge), theirs = room(neighbour, edge == .start ? .end : .start)
        var longest = min(clip.duration, neighbour.duration)
        if let handles = [mine, theirs].compactMap({ $0 }).min() { longest = min(longest, handles * 2) }
        return settings.frameRate.floor(longest)
    }

    /// Sets (or with `nil` removes) the transition at a clip's edge, shortened to fit.
    /// A transition into a butted clip is stored on that clip's `transitionIn`.
    @discardableResult
    mutating func setTransition(_ transition: ClipTransition?, on id: ClipID, edge: TrimEdge) throws -> ClipTransition? {
        guard let (t, i) = location(of: id) else { throw EditError.clipNotFound }
        try requireUnlocked(t)
        let clips = tracks[t].clips
        if edge == .end, i + 1 < clips.count, clips[i + 1].start == clips[i].end {
            return try setTransition(transition, on: clips[i + 1].id, edge: .start)
        }
        var fitted = transition
        if var value = fitted {
            value.duration = min(snap(value.duration), maxTransitionDuration(id, edge: edge))
            fitted = value.duration > .zero ? value : nil
        }
        if edge == .start { tracks[t].clips[i].transitionIn = fitted } else { tracks[t].clips[i].transitionOut = fitted }
        return fitted
    }

    // MARK: Tracks and markers

    @discardableResult
    mutating func addTrack(_ kind: Track.Kind, name: String? = nil, at index: Int? = nil) -> TrackID {
        let prefix = kind == .audio ? "A" : (kind == .title ? "T" : "V")
        let count = tracks.filter { $0.kind == kind }.count
        let track = Track(kind: kind, name: name ?? "\(prefix)\(count + 1)")
        tracks.insert(track, at: min(index ?? tracks.count, tracks.count))
        return track.id
    }

    mutating func removeTrack(_ id: TrackID) throws {
        guard let t = trackIndex(id) else { throw EditError.trackNotFound }
        guard t > 0 else { throw EditError.invalid("The primary storyline can't be removed.") }
        try requireUnlocked(t)
        tracks.remove(at: t)
    }

    @discardableResult
    mutating func addMarker(at time: Time, name: String = "", kind: Marker.Kind = .standard) -> MarkerID {
        let marker = Marker(time: snap(max(.zero, time)), name: name, kind: kind)
        markers.insert(marker, at: markers.firstIndex { $0.time > marker.time } ?? markers.endIndex)
        return marker.id
    }

    mutating func moveMarker(_ id: MarkerID, to time: Time) {
        guard let i = markers.firstIndex(where: { $0.id == id }) else { return }
        var marker = markers.remove(at: i)
        marker.time = snap(max(.zero, time))
        markers.insert(marker, at: markers.firstIndex { $0.time > marker.time } ?? markers.endIndex)
    }

    mutating func removeMarkers(_ ids: Set<MarkerID>) {
        markers.removeAll { ids.contains($0.id) }
    }

    // MARK: Ripple machinery

    private func requireUnlocked(_ t: Int) throws {
        if tracks[t].isLocked { throw EditError.trackLocked(tracks[t].name) }
    }

    private func unlockedIndices(_ ids: Set<TrackID>) throws -> [Int] {
        try ids.map { id in
            guard let t = trackIndex(id) else { throw EditError.trackNotFound }
            try requireUnlocked(t)
            return t
        }
    }

    /// The tracks a ripple on `targets` touches, and whether markers move with it.
    private func rippleSet(_ targets: Set<Int>) -> (tracks: [Int], movesMarkers: Bool) {
        let synced = targets.contains { tracks[$0].isSyncLocked }
        var all = targets
        if synced {
            for t in tracks.indices where tracks[t].isSyncLocked && !tracks[t].isLocked { all.insert(t) }
        }
        return (all.sorted(), synced)
    }

    /// Removes `ranges` (any order) from `targets` and the tracks that ripple with them.
    private mutating func removeTime(_ ranges: [TimeRange], rippling targets: Set<Int>) {
        let (all, movesMarkers) = rippleSet(targets)
        var regroup = Regroup()
        for r in merged(ranges).reversed() {
            for t in all { tracks[t].removeTime(r, regroup: &regroup) }
            guard movesMarkers else { continue }
            for m in markers.indices where markers[m].time >= r.start {
                markers[m].time = markers[m].time >= r.end ? markers[m].time - r.duration : r.start
            }
        }
    }

    private mutating func insertTime(at time: Time, _ length: Time, tracks all: [Int], movesMarkers: Bool, regroup: inout Regroup) {
        for t in all { tracks[t].insertTime(at: time, length, regroup: &regroup) }
        if movesMarkers {
            for m in markers.indices where markers[m].time >= time { markers[m].time += length }
        }
    }

    /// Swaps in a clip with the same start but a new length, moving later clips on its
    /// track by the difference. Other rippling tracks gain or lose that time at `point`.
    private mutating func replaceRippling(track t: Int, index i: Int, with new: Clip, at point: Time) {
        let old = tracks[t].clips[i]
        let change = new.duration - old.duration
        tracks[t].clips[i] = new
        for j in tracks[t].clips.indices where j > i { tracks[t].clips[j].start += change }
        let (all, movesMarkers) = rippleSet([t])
        let others = all.filter { $0 != t }
        var regroup = Regroup()
        if change < .zero {
            let r = TimeRange(start: point, duration: -change)
            for o in others { tracks[o].removeTime(r, regroup: &regroup) }
            if movesMarkers {
                for m in markers.indices where markers[m].time >= r.start {
                    markers[m].time = markers[m].time >= r.end ? markers[m].time - r.duration : r.start
                }
            }
        } else if change > .zero {
            insertTime(at: point, change, tracks: others, movesMarkers: movesMarkers, regroup: &regroup)
        }
    }

    /// Validates clips for `track` and lays them end to end from `time`, with fresh IDs
    /// where an ID is already taken.
    private func layOut(_ clips: [Clip], at time: Time, on id: TrackID) throws -> (Int, [Clip]) {
        guard let t = trackIndex(id) else { throw EditError.trackNotFound }
        try requireUnlocked(t)
        let taken = Set(tracks.flatMap(\.clips).map(\.id))
        var cursor = snap(max(.zero, time))
        var laid: [Clip] = []
        for var clip in clips {
            if let sourceID = clip.sourceID, source(sourceID) == nil { throw EditError.sourceNotFound }
            guard tracks[t].accepts(clip.content, source: clip.sourceID.flatMap(source)) else { throw EditError.wrongTrack(tracks[t].name) }
            if taken.contains(clip.id) || laid.contains(where: { $0.id == clip.id }) { clip.id = ClipID() }
            clip.start = cursor
            clip.duration = max(frameDuration, snap(clip.duration))
            cursor = clip.end
            laid.append(clip)
        }
        return (t, laid)
    }

    /// Parts of `range` where none of `targets` has a clip.
    private func emptyParts(of range: TimeRange, on targets: Set<Int>) -> [TimeRange] {
        let occupied = merged(targets.flatMap { t in tracks[t].clips.compactMap { $0.range.intersection(range) } })
        var result: [TimeRange] = []
        var cursor = range.start
        for r in occupied {
            if r.start > cursor { result.append(TimeRange(start: cursor, end: r.start)) }
            cursor = max(cursor, r.end)
        }
        if cursor < range.end { result.append(TimeRange(start: cursor, end: range.end)) }
        return result
    }
}

/// Sorted, with overlapping and touching ranges joined.
nonisolated func merged(_ ranges: [TimeRange]) -> [TimeRange] {
    var result: [TimeRange] = []
    for r in ranges.filter({ !$0.isEmpty }).sorted(by: { $0.start < $1.start }) {
        if let last = result.last, r.start <= last.end {
            result[result.count - 1] = TimeRange(start: last.start, end: max(last.end, r.end))
        } else {
            result.append(r)
        }
    }
    return result
}
