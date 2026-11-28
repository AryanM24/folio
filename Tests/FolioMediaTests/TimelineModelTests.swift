import AVFoundation
import AppKit
import Testing
import UniformTypeIdentifiers

@testable import FolioMedia

/// The frame rates every edit must stay exact at.
nonisolated private let rates: [FrameRate] = [.fps23_976, .fps29_97, .fps25, .fps60]

/// V1 holds three butted clips of 48, 72 and 24 frames, cut from one long movie at source
/// frames 100, 1100 and 2100. A1 is empty. Every test starts from this.
nonisolated private struct Fixture {
    let rate: FrameRate
    var project: Project
    let source: MediaSource

    init(_ rate: FrameRate, lengths: [Int64] = [48, 72, 24]) throws {
        self.rate = rate
        project = Project(settings: ProjectSettings(frameRate: rate))
        source = MediaSource(name: "a.mov", kind: .video, duration: rate.time(ofFrame: 10_000), frameRate: rate, hasAudio: true)
        project.sources = [source]
        let clips = lengths.enumerated().map { i, n in
            Clip(
                source: source, range: TimeRange(start: rate.time(ofFrame: Int64(i) * 1000 + 100), duration: rate.time(ofFrame: n)),
                frameRate: rate)
        }
        try project.append(clips, track: project.tracks[0].id)
    }

    func f(_ n: Int64) -> Time { rate.time(ofFrame: n) }
    var v1: [Clip] { project.tracks[0].clips }
    var a1: [Clip] { project.tracks[1].clips }
    /// Clip lengths on V1, in frames.
    var lengths: [Int64] { v1.map { rate.frame(at: $0.duration) } }
    var starts: [Int64] { v1.map { rate.frame(at: $0.start) } }
}

// MARK: - Time

@Suite(.timeLimit(.minutes(1))) struct TimelineModelTimeTests {
    @Test func ntscFramesAreExact() {
        let rate = FrameRate.fps23_976
        var sum = Time.zero
        for _ in 0..<1001 { sum += rate.frameDuration }
        #expect(sum == Time(value: 1001 * 1001, timescale: 24000))
        #expect(sum == rate.time(ofFrame: 1001))
        #expect(rate.frame(at: sum) == 1001)
        #expect(rate.frame(at: sum - Time(value: 1, timescale: 705_600_000)) == 1000)
        // 1 s at 23.976 is 23.976 frames: the nearest boundary is frame 24, at 1.001 s.
        #expect(rate.snap(Time(seconds: 1)) == Time(value: 1001, timescale: 1000))
    }

    @Test func equalTimesHashAlike() {
        #expect(Time(value: 1, timescale: 2) == Time(value: 12000, timescale: 24000))
        #expect(Set([Time(value: 1, timescale: 2), Time(value: 12000, timescale: 24000)]).count == 1)
        #expect(Time(value: 1001, timescale: 24000) + Time(value: 1001, timescale: 30000) == Time(value: 9009, timescale: 120_000))
        #expect(Time(value: 1001, timescale: 24000) < Time(value: 1001, timescale: 23999))
    }

    @Test func speedMathIsExact() {
        let frame = FrameRate.fps23_976.frameDuration
        #expect(frame * Rational(3, 2) == Time(value: 3003, timescale: 48000))
        #expect(frame / Rational(2) == Time(value: 1001, timescale: 48000))
        #expect(Rational(approximating: 1.37) == Rational(137, 100))
        #expect(Rational(4, -8) == Rational(-1, 2))
    }

    @Test func unstorableTimesRoundToFlicks() {
        let odd = Time(value: 1, timescale: 1_000_003) * Rational(1, 1_000_033)
        #expect(odd.timescale == Time.flicks)
        // Flicks hold NTSC frame boundaries exactly.
        let frame = FrameRate.fps29_97.frameDuration
        #expect(Time.exact(Int128(frame.value) * Int128(Time.flicks), Int128(frame.timescale) * Int128(Time.flicks)) == frame)
    }

    @Test func cmTimeRoundTrip() {
        let t = Time(value: 1001, timescale: 30000)
        #expect(Time(t.cmTime) == t)
        #expect(Time(CMTime.invalid) == nil)
        let r = TimeRange(start: t, duration: t * 10)
        #expect(TimeRange(r.cmTimeRange) == r)
    }

    @Test func encodesAsFractions() throws {
        let data = try JSONEncoder().encode([Time(value: 1001, timescale: 24000)])
        #expect(String(decoding: data, as: UTF8.self) == #"["1001\/24000"]"#)
        #expect(try JSONDecoder().decode([Time].self, from: data) == [Time(value: 1001, timescale: 24000)])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([Time].self, from: Data(#"["1/0"]"#.utf8)) }
        #expect(try JSONDecoder().decode([FrameRate].self, from: JSONEncoder().encode([FrameRate.fps59_94])) == [.fps59_94])
        #expect(FrameRate.fps23_976.description == "23.976")
        #expect(FrameRate.fps29_97.description == "29.97")
    }

    @Test func canvasPresetsAreEven() {
        #expect(CanvasSize(.vertical).width == 1080 && CanvasSize(.vertical).height == 1920)
        #expect(CanvasSize(.portrait).height == 1350)
        #expect(CanvasSize(.cinema).width == 2520)
        #expect(CanvasSize(width: 1281, height: 721).width == 1280)
        #expect(CanvasSize(.square, shortEdge: 720).aspect == .square)
    }
}

// MARK: - Edits

@Suite(.timeLimit(.minutes(1))) struct TimelineModelEditTests {
    @Test(arguments: rates) func split(rate: FrameRate) throws {
        var x = try Fixture(rate)
        let middle = x.v1[1]
        // Slightly off the grid: the split snaps to frame 78.
        let made = try x.project.split(at: x.f(78) + Time(seconds: 0.2 / rate.perSecond))
        #expect(made.count == 1)
        #expect(x.lengths == [48, 30, 42, 24])
        #expect(x.v1[2].sourceStart == middle.sourceStart + x.f(30))
        #expect(x.v1[1].id == middle.id && x.v1[2].id != middle.id)
        #expect(x.project.duration == x.f(144))
        #expect(x.project.problems.isEmpty)
    }

    @Test(arguments: rates) func trimWithoutRippleStopsAtNeighbours(rate: FrameRate) throws {
        var x = try Fixture(rate)
        let id = x.v1[1].id
        #expect(try x.project.trim(id, edge: .end, to: x.f(110)) == -x.f(10))
        #expect(x.lengths == [48, 62, 24] && x.starts == [0, 48, 120])
        // Pulling it back out stops at the next clip.
        #expect(try x.project.trim(id, edge: .end, to: x.f(500)) == x.f(10))
        // The first clip can't start before zero.
        #expect(try x.project.trim(x.v1[0].id, edge: .start, to: -x.f(5)) == .zero)
        // A clip never gets shorter than a frame.
        try x.project.trim(id, edge: .start, to: x.f(400))
        #expect(x.lengths[1] == 1)
        #expect(x.project.problems.isEmpty)
    }

    @Test(arguments: rates) func rippleTrim(rate: FrameRate) throws {
        var x = try Fixture(rate)
        let middle = x.v1[1]
        try x.project.trim(middle.id, edge: .end, to: x.f(110), ripple: true)
        #expect(x.lengths == [48, 62, 24] && x.starts == [0, 48, 110])
        try x.project.trim(middle.id, edge: .start, to: x.f(54), ripple: true)
        #expect(x.lengths == [48, 56, 24] && x.starts == [0, 48, 104])
        #expect(x.v1[1].sourceStart == middle.sourceStart + x.f(6))
        // Ripple-extending the head uses the handle before the source start.
        try x.project.trim(middle.id, edge: .start, to: x.f(38), ripple: true)
        #expect(x.lengths == [48, 66, 24] && x.v1[1].sourceStart == middle.sourceStart - x.f(4))
        #expect(x.project.problems.isEmpty)
    }

    @Test func trimStopsAtTheEndOfTheMedia() throws {
        var x = try Fixture(.fps25)
        // Clip 0 uses source frames 100…147; it can only grow 100 frames at the head.
        #expect(x.project.room(x.v1[0], .start) == x.f(100))
        try x.project.trim(x.v1[0].id, edge: .start, to: -x.f(1000), ripple: true)
        #expect(x.v1[0].sourceStart == .zero && x.lengths[0] == 148)
        #expect(x.project.problems.isEmpty)
    }

    @Test(arguments: rates) func rollKeepsTheLength(rate: FrameRate) throws {
        var x = try Fixture(rate)
        let right = x.v1[1]
        #expect(try x.project.roll(x.v1[0].id, by: x.f(5)) == x.f(5))
        #expect(x.lengths == [53, 67, 24] && x.starts == [0, 53, 120])
        #expect(x.v1[1].sourceStart == right.sourceStart + x.f(5))
        #expect(throws: EditError.noAdjacentClip) { try x.project.roll(x.v1[2].id, by: x.f(1)) }
        #expect(x.project.problems.isEmpty)
    }

    @Test(arguments: rates) func slipMovesOnlyTheMedia(rate: FrameRate) throws {
        var x = try Fixture(rate)
        let clip = x.v1[1]
        #expect(try x.project.slip(clip.id, by: x.f(10)) == x.f(10))
        #expect(x.v1[1].sourceStart == clip.sourceStart + x.f(10) && x.v1[1].range == clip.range)
        try x.project.slip(clip.id, by: -x.f(100_000))
        #expect(x.v1[1].sourceStart == .zero)
        try x.project.slip(clip.id, by: x.f(100_000))
        #expect(x.v1[1].sourceRange.end == x.source.duration)
        #expect(x.project.problems.isEmpty)
    }

    @Test(arguments: rates) func slideTradesWithNeighbours(rate: FrameRate) throws {
        var x = try Fixture(rate)
        let clip = x.v1[1]
        #expect(try x.project.slide(clip.id, by: x.f(4)) == x.f(4))
        #expect(x.lengths == [52, 72, 20] && x.starts == [0, 52, 124])
        #expect(x.v1[1].sourceStart == clip.sourceStart)
        // The right neighbour keeps at least a frame.
        #expect(try x.project.slide(clip.id, by: x.f(100)) == x.f(19))
        #expect(x.project.duration == x.f(144))
        #expect(x.project.problems.isEmpty)
    }

    @Test(arguments: rates) func liftAndRippleDelete(rate: FrameRate) throws {
        var x = try Fixture(rate)
        var lifted = x
        try lifted.project.lift(clips: [x.v1[1].id])
        #expect(lifted.starts == [0, 120] && lifted.project.duration == x.f(144))
        try x.project.rippleDelete(clips: [x.v1[1].id])
        #expect(x.starts == [0, 48] && x.project.duration == x.f(72))
        #expect(x.project.problems.isEmpty)
    }

    @Test func rippleCarriesSyncLockedTracks() throws {
        var x = try Fixture(.fps30)
        let music = MediaSource(name: "music.m4a", kind: .audio, duration: x.f(10_000))
        x.project.sources.append(music)
        try x.project.append(
            [Clip(source: music, range: TimeRange(start: .zero, duration: x.f(144)), frameRate: x.rate)], track: x.project.tracks[1].id)
        x.project.addMarker(at: x.f(130), name: "End", kind: .chapter)
        var unsynced = x
        try x.project.rippleDelete(clips: [x.v1[1].id])
        // The music lost the same 72 frames, cut where the clip was, and the marker moved.
        #expect(x.a1.map { x.rate.frame(at: $0.duration) } == [48, 24])
        #expect(x.a1[1].start == x.f(48) && x.a1[1].sourceStart == x.f(120))
        #expect(x.project.markers[0].time == x.f(58))
        #expect(x.project.problems.isEmpty)

        unsynced.project.tracks[1].isSyncLocked = false
        try unsynced.project.rippleDelete(clips: [unsynced.v1[1].id])
        #expect(unsynced.a1.count == 1 && unsynced.a1[0].duration == x.f(144))
    }

    @Test(arguments: rates) func extractAndLiftRange(rate: FrameRate) throws {
        var x = try Fixture(rate)
        let v1 = x.project.tracks[0].id
        var lifted = x
        try lifted.project.lift(range: TimeRange(start: x.f(40), end: x.f(60)), tracks: [v1])
        #expect(lifted.lengths == [40, 60, 24] && lifted.starts == [0, 60, 120])
        try x.project.extract(range: TimeRange(start: x.f(40), end: x.f(60)), tracks: [v1])
        #expect(x.lengths == [40, 60, 24] && x.starts == [0, 40, 100])
        #expect(x.v1[1].sourceStart == x.f(1112))
        #expect(x.project.problems.isEmpty)
    }

    @Test(arguments: rates) func placeClips(rate: FrameRate) throws {
        var x = try Fixture(rate)
        let v1 = x.project.tracks[0].id
        let extra = Clip(source: x.source, range: TimeRange(start: x.f(5000), duration: x.f(10)), frameRate: rate)
        var overwritten = x
        try x.project.insert([extra], at: x.f(60), track: v1)
        #expect(x.lengths == [48, 12, 10, 60, 24] && x.project.duration == x.f(154))
        try overwritten.project.overwrite([extra], at: x.f(60), track: v1)
        #expect(overwritten.lengths == [48, 12, 10, 50, 24] && overwritten.project.duration == x.f(144))
        try overwritten.project.append([Clip(content: .color(.white), duration: x.f(5))], track: v1)
        #expect(overwritten.project.duration == x.f(149))
        #expect(throws: EditError.wrongTrack("A1")) {
            try x.project.insert([Clip(content: .title(Title(text: "Hi")), duration: x.f(5))], at: .zero, track: x.project.tracks[1].id)
        }
        #expect(x.project.problems.isEmpty && overwritten.project.problems.isEmpty)
    }

    @Test(arguments: rates) func moveClips(rate: FrameRate) throws {
        var x = try Fixture(rate)
        let last = x.v1[2]
        var reordered = x
        // Insert-drag the last clip to the front: a reorder, nothing else moves.
        try reordered.project.move([last.id], by: -last.start, mode: .insert)
        #expect(reordered.lengths == [24, 48, 72] && reordered.starts == [0, 24, 72])
        #expect(reordered.v1[0].id == last.id)
        // Overwrite-drag the middle clip up to a new video track.
        x.project.addTrack(.video)
        try x.project.move([x.v1[1].id], by: x.f(2), trackOffset: 2)
        #expect(x.starts == [0, 120] && x.project.tracks[2].clips.first?.start == x.f(50))
        #expect(throws: EditError.trackNotFound) { try x.project.move([x.v1[0].id], by: .zero, trackOffset: 5) }
        #expect(x.project.problems.isEmpty && reordered.project.problems.isEmpty)
    }

    @Test func groupsMoveTogether() throws {
        var x = try Fixture(.fps24)
        let sound = try x.project.detachAudio(x.v1[0].id)
        #expect(x.a1.first?.id == sound && x.v1[0].audio.isEnabled == false)
        #expect(x.project.expandingGroups([sound]).count == 2)
        try x.project.move([sound], by: x.f(200))
        #expect(x.v1.last?.start == x.f(200) && x.a1[0].start == x.f(200))
        x.project.ungroup([sound])
        #expect(x.project.expandingGroups([sound]).count == 1)
        let group = try x.project.group([x.v1[0].id, x.v1[1].id])
        #expect(x.v1[0].groupID == group)
        #expect(throws: EditError.noSound) { try x.project.detachAudio(x.v1.last!.id) }
        #expect(x.project.problems.isEmpty)
    }

    @Test func splitKeepsLinkedPiecesTogether() throws {
        var x = try Fixture(.fps25)
        try x.project.detachAudio(x.v1[0].id)
        try x.project.split(x.v1[0].id, at: x.f(20))
        #expect(x.v1.count == 4 && x.a1.count == 2)
        #expect(x.v1[1].groupID == x.a1[1].groupID && x.v1[0].groupID != x.v1[1].groupID)
        #expect(x.project.problems.isEmpty)
    }

    @Test func duplicateAndPaste() throws {
        var x = try Fixture(.fps29_97)
        let made = try x.project.duplicate([x.v1[0].id])
        #expect(made.count == 1 && x.lengths == [48, 48, 72, 24])
        #expect(x.v1[1].sourceStart == x.v1[0].sourceStart && x.v1[1].id != x.v1[0].id)
        // Paste into an empty project brings the media along.
        let bundle = try #require(x.project.copy([x.v1[2].id]))
        var other = Project()
        try other.paste(bundle, at: .zero, track: other.tracks[0].id)
        #expect(other.sources.map(\.id) == [x.source.id] && other.tracks[0].clips.count == 1)
        #expect(other.problems.isEmpty && x.project.problems.isEmpty)
    }

    @Test func pasteAttributes() throws {
        var x = try Fixture(.fps25)
        var look = x.v1[0]
        look.effects = [Effect(.look(.noir)), Effect(.blur())]
        look.transform.scale.setConstant(0.5)
        try x.project.pasteAttributes(from: look, to: [x.v1[1].id, x.v1[2].id], [.effects, .transform])
        #expect(x.v1[2].effects.map(\.kind) == look.effects.map(\.kind) && x.v1[2].effects[0].id != look.effects[0].id)
        #expect(x.v1[1].transform.scale.value == 0.5)
    }

    @Test(arguments: rates) func closeGapsNeverCuts(rate: FrameRate) throws {
        var x = try Fixture(rate)
        try x.project.lift(clips: [x.v1[1].id])
        x.project.addTrack(.title)
        // A title over part of the gap, on a sync-locked track: only the rest can close.
        try x.project.overwrite([Clip(content: .title(Title(text: "Hi")), duration: x.f(12))], at: x.f(60), track: x.project.tracks[2].id)
        try x.project.closeGaps(in: x.project.tracks[0].id)
        #expect(x.starts == [0, 60] && x.project.tracks[2].clips[0].range == TimeRange(start: x.f(48), duration: x.f(12)))
        #expect(x.project.problems.isEmpty)
    }

    @Test(arguments: rates) func speed(rate: FrameRate) throws {
        var x = try Fixture(rate)
        let clip = x.v1[1]
        try x.project.setSpeed(clip.id, Rational(2))
        #expect(x.lengths == [48, 36, 24] && x.starts == [0, 48, 84])
        #expect(x.v1[1].sourceRange == clip.sourceRange)
        try x.project.setSpeed(clip.id, Rational(1, 2))
        #expect(x.lengths == [48, 144, 24])
        #expect(
            x.v1[1].timeMap() == [TimeMapSegment(timeline: x.v1[1].range, source: clip.sourceRange, speed: Rational(1, 2), reversed: false)]
        )
        #expect(throws: EditError.self) { try x.project.setSpeed(clip.id, .zero) }
        #expect(x.project.problems.isEmpty)
    }

    @Test func speedRampsAndReverse() throws {
        let x = try Fixture(.fps24)
        var clip = x.v1[1]
        clip.retime.segments = [SpeedSegment(start: .zero, speed: .one), SpeedSegment(start: x.f(24), speed: Rational(2))]
        #expect(clip.sourceDuration == x.f(24 + 96))
        #expect(clip.retime.timelineOffset(forSource: x.f(40)) == x.f(32))
        let pieces = clip.timeMap()
        #expect(pieces.map(\.source.duration) == [x.f(24), x.f(96)])
        #expect(pieces[1].timeline.start == clip.start + x.f(24))
        // Splitting inside the fast part keeps the speed on the right piece.
        let right = clip.reframed(to: TimeRange(start: clip.start + x.f(30), end: clip.end))
        #expect(right.retime.constantSpeed == Rational(2) && right.sourceStart == clip.sourceStart + x.f(36))
        clip.retime.reversed = true
        #expect(clip.sourceTime(atOffset: .zero) == clip.sourceRange.end)
        #expect(
            clip.timelineRange(forSource: TimeRange(start: clip.sourceRange.end - x.f(24), duration: x.f(24)))
                == TimeRange(start: clip.start, duration: x.f(24)))
        // Reversed clips cut from the other end of the media.
        let head = clip.reframed(to: TimeRange(start: clip.start, duration: x.f(24)))
        #expect(head.sourceRange.end == clip.sourceRange.end)
    }

    @Test func freezeFrame() throws {
        var x = try Fixture(.fps30)
        let clip = x.v1[1]
        let freeze = try x.project.freezeFrame(at: x.f(60), track: x.project.tracks[0].id, duration: x.f(30))
        #expect(x.lengths == [48, 12, 30, 60, 24])
        #expect(x.v1[2].id == freeze && x.v1[2].content == .freeze(source: x.source.id, at: clip.sourceStart + x.f(12)))
        #expect(x.project.problems.isEmpty)
    }

    @Test func transitionsFitTheirHandles() throws {
        var x = try Fixture(.fps25)
        // Clip 0 ends at source frame 148 of 10 000: plenty of handle. Clip 1 starts at 1100.
        let set = try x.project.setTransition(ClipTransition(duration: x.f(20)), on: x.v1[0].id, edge: .end)
        #expect(set?.duration == x.f(20) && x.v1[1].transitionIn?.duration == x.f(20) && x.v1[0].transitionOut == nil)
        // Never longer than the shorter clip.
        try x.project.setTransition(ClipTransition(duration: x.f(500)), on: x.v1[2].id, edge: .start)
        #expect(x.v1[2].transitionIn?.duration == x.f(24))
        // A split inside a clip drops the transition from the new edges only.
        try x.project.split(at: x.f(130))
        #expect(x.v1[2].transitionIn != nil && x.v1[3].transitionIn == nil)
    }

    @Test func lockedTracksRefuseEdits() throws {
        var x = try Fixture(.fps25)
        x.project.tracks[0].isLocked = true
        let before = x.project
        #expect(throws: EditError.trackLocked("V1")) { try x.project.rippleDelete(clips: [x.v1[0].id]) }
        #expect(throws: EditError.trackLocked("V1")) { try x.project.trim(x.v1[0].id, edge: .end, to: .zero) }
        // Blade skips locked tracks unless asked for them.
        #expect(try x.project.split(at: x.f(10)).isEmpty)
        #expect(x.project == before)
    }

    @Test func reverseAndTracks() throws {
        var x = try Fixture(.fps25)
        let clip = x.v1[1]
        try x.project.setReversed(clip.id, true)
        #expect(x.v1[1].retime.reversed && x.v1[1].range == clip.range && x.v1[1].sourceRange == clip.sourceRange)
        #expect(throws: EditError.notMedia) {
            try x.project.insert([Clip(content: .color(.black), duration: x.f(5))], at: .zero, track: x.project.tracks[0].id)
            try x.project.setReversed(x.v1[0].id, true)
        }
        let v2 = x.project.addTrack(.video, at: 1)
        #expect(x.project.tracks.map(\.name) == ["V1", "V2", "A1"])
        try x.project.removeTrack(v2)
        #expect(throws: EditError.self) { try x.project.removeTrack(x.project.tracks[0].id) }
        #expect(x.project.tracks.count == 2)
    }

    @Test func markers() throws {
        var x = try Fixture(.fps25)
        let a = x.project.addMarker(at: x.f(100), name: "B", kind: .chapter)
        x.project.addMarker(at: x.f(10), name: "A")
        #expect(x.project.markers.map(\.name) == ["A", "B"] && x.project.chapters.map(\.id) == [a])
        x.project.moveMarker(a, to: .zero)
        #expect(x.project.markers.map(\.name) == ["B", "A"])
        try x.project.insert([Clip(content: .color(.black), duration: x.f(5))], at: .zero, track: x.project.tracks[0].id)
        #expect(x.project.markers.map(\.time) == [x.f(5), x.f(15)])
        x.project.removeMarkers([a])
        #expect(x.project.markers.count == 1)
    }
}

// MARK: - Keyframes

@Suite(.timeLimit(.minutes(1))) struct TimelineModelKeyframeTests {
    let second = Time(value: 1, timescale: 1)

    @Test func interpolates() {
        var k = Keyframed(0.0)
        #expect(k.value(at: second) == 0)
        k.set(0, at: .zero)
        k.set(1, at: second * 2)
        #expect(k.value(at: second) == 0.5)
        #expect(k.value(at: second * 9) == 1)
        k.set(0, at: .zero, interpolation: .easeInOut)
        #expect(k.value(at: second) == 0.5)
        #expect(k.value(at: Time(seconds: 0.5)) < 0.25)
        k.set(0, at: .zero, interpolation: .hold)
        #expect(k.value(at: Time(seconds: 1.9)) == 0)
    }

    @Test func splitKeepsTheAnimation() throws {
        var x = try Fixture(.fps24)
        try x.project.trim(x.v1[0].id, edge: .end, to: x.f(48))
        var clip = x.v1[0]
        clip.transform.opacity.set(0, at: .zero)
        clip.transform.opacity.set(1, at: x.f(48))
        x.project.tracks[0].clips[0] = clip
        try x.project.split(at: x.f(12))
        let left = x.v1[0].transform.opacity, right = x.v1[1].transform.opacity
        #expect(left.value(at: x.f(12)) == 0.25 && right.value(at: .zero) == 0.25)
        #expect(abs(right.value(at: x.f(24)) - 0.75) < 1e-9 && right.value(at: x.f(36)) == 1)
    }

    @Test func constantsEncodeBare() throws {
        let json = try JSONEncoder().encode(Keyframed(0.5))
        #expect(String(decoding: json, as: UTF8.self) == "0.5")
        var k = Keyframed(Vec2.zero)
        k.set(Vec2(x: 1, y: 2), at: .zero)
        #expect(try JSONDecoder().decode(Keyframed<Vec2>.self, from: JSONEncoder().encode(k)) == k)
        #expect(try JSONDecoder().decode(Keyframed<Vec2>.self, from: JSONEncoder().encode(Keyframed(Vec2(x: 3, y: 4)))).value.y == 4)
    }
}

// MARK: - Words and captions

@Suite(.timeLimit(.minutes(1))) struct TimelineModelCaptionTests {
    /// One clip of a talking-head source; the transcript has a word every 10 frames.
    private func talk() throws -> Fixture {
        var x = try Fixture(.fps25, lengths: [100])
        let words = (0..<10).map { i in
            Word(text: "w\(i)", range: TimeRange(start: x.f(100 + Int64(i) * 10), duration: x.f(8)))
        }
        x.project.setTranscript(Transcript(sourceID: x.source.id, locale: "en-US", words: words))
        var captions = CaptionTrack()
        captions.cues = [
            CaptionCue(
                text: "w0 w1 w2 w3 w4", range: TimeRange(start: x.f(100), duration: x.f(48)), source: x.source.id,
                words: Array(words[0..<5]))
        ]
        x.project.captions = [captions]
        return x
    }

    @Test func wordsMapThroughEdits() throws {
        var x = try talk()
        #expect(x.project.timelineWords().map(\.range.start) == (0..<10).map { x.f(Int64($0) * 10) })
        // Delete w2 (frames 20…28) by its timeline range; padding keeps the neighbours whole.
        let w2 = x.project.timelineWords()[2]
        try x.project.cut(wordRanges: [w2.range], padding: x.f(1))
        let after = x.project.timelineWords()
        #expect(after.map(\.text) == ["w0", "w1", "w3", "w4", "w5", "w6", "w7", "w8", "w9"])
        #expect(x.project.duration == x.f(94))
        #expect(x.project.problems.isEmpty)
    }

    @Test func cuesFollowCutsAndDropCutWords() throws {
        var x = try talk()
        try x.project.cut(wordRanges: [x.project.timelineWords()[2].range], padding: .zero)
        let cues = x.project.resolvedCues(x.project.captions[0])
        #expect(cues.count == 1)
        #expect(cues[0].text == "w0 w1 w3 w4" && cues[0].range == TimeRange(start: .zero, duration: x.f(40)))
        // A duplicated clip shows its captions twice.
        try x.project.duplicate([x.v1[0].id, x.v1[1].id])
        #expect(x.project.resolvedCues(x.project.captions[0]).count == 2)
    }
}

// MARK: - Undo

@Suite(.timeLimit(.minutes(1))) struct TimelineModelStoreTests {
    private func store() throws -> (ProjectStore, UndoManager, Project) {
        let project = try Fixture(.fps23_976).project
        let store = ProjectStore(project: project)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        return (store, undo, project)
    }

    @Test func undoAndRedoRoundTrip() throws {
        let (store, undo, original) = try store()
        try store.edit("Split Clip") { try $0.split(at: FrameRate.fps23_976.time(ofFrame: 10)) }
        let split = store.project
        try store.edit("Ripple Delete") { try $0.rippleDelete(clips: [$0.tracks[0].clips[0].id]) }
        #expect(undo.undoActionName == "Ripple Delete")
        undo.undo()
        #expect(store.project == split)
        undo.undo()
        #expect(store.project == original)
        #expect(!undo.canUndo && undo.redoActionName == "Split Clip")
        undo.redo()
        undo.redo()
        #expect(store.project.tracks[0].clips.count == 3 && store.project != split)
    }

    @Test func gesturesAreOneStep() throws {
        let (store, undo, original) = try store()
        let id = original.tracks[0].clips[1].id
        store.beginGesture("Trim")
        for n in 1...10 {
            try store.edit("Trim") { try $0.trim(id, edge: .end, to: FrameRate.fps23_976.time(ofFrame: 120 - Int64(n)), ripple: true) }
        }
        store.endGesture()
        #expect(store.project.tracks[0].clips[1].duration == FrameRate.fps23_976.time(ofFrame: 62))
        undo.undo()
        #expect(store.project == original && !undo.canUndo)

        store.beginGesture("Trim")
        try store.edit("Trim") { try $0.trim(id, edge: .end, to: .zero) }
        store.cancelGesture()
        #expect(store.project == original && !undo.canUndo)
    }

    @Test func failedOrEmptyEditsLeaveNoTrace() throws {
        let (store, undo, original) = try store()
        #expect(throws: EditError.self) {
            try store.edit("Delete") { p in
                try p.lift(clips: [p.tracks[0].clips[0].id])
                throw EditError.invalid("stop")
            }
        }
        store.edit("Nothing") { _ in }
        #expect(store.project == original && !undo.canUndo)
    }
}

// MARK: - File and media

@Suite(.timeLimit(.minutes(1))) struct TimelineModelFileTests {
    @Test func jsonRoundTrips() throws {
        var x = try Fixture(.fps29_97)
        try x.project.detachAudio(x.v1[0].id)
        x.project.tracks[0].clips[1].effects = [
            Effect(.color(ColorAdjustments(exposure: 0.5))), Effect(.redact([RedactRegion(rect: Keyframed(.full))])),
        ]
        x.project.tracks[0].clips[1].transform.position.set(Vec2(x: 0.1, y: 0), at: .zero, interpolation: .easeOut)
        try x.project.setTransition(ClipTransition(kind: .push, duration: x.f(10)), on: x.v1[1].id, edge: .start)
        x.project.addMarker(at: x.f(3), name: "Intro", kind: .chapter)
        x.project.captions = [CaptionTrack()]
        let data = try ProjectFile.encode(x.project)
        #expect(try ProjectFile.decode(data) == x.project)
        // Sorted keys: the same project always writes the same bytes.
        #expect(try ProjectFile.encode(ProjectFile.decode(data)) == data)
    }

    @Test func refusesNewerFormatsInPlainLanguage() throws {
        var json = try JSONSerialization.jsonObject(with: ProjectFile.encode(Project())) as? [String: Any] ?? [:]
        json["version"] = Project.currentVersion + 1
        let error = #expect(throws: (any Error).self) { try ProjectFile.decode(JSONSerialization.data(withJSONObject: json)) }
        #expect(error?.localizedDescription.contains("newer version of Folio") == true)
        let garbage = #expect(throws: (any Error).self) { try ProjectFile.decode(Data("{\"version\":1}".utf8)) }
        #expect(garbage?.localizedDescription.contains("damaged") == true)
        #expect(throws: (any Error).self) { try ProjectFile.decode(Data("not json".utf8)) }
    }

    @Test func documentSnapshotsTheStore() throws {
        let document = VideoProjectDocument()
        #expect(document.store.project.tracks.map(\.kind) == [.video, .audio])
        document.store.edit("Add Track") { $0.addTrack(.title) }
        #expect(try document.snapshot(contentType: .folioVideoProject).project.tracks.count == 3)
        #expect(UTType.folioVideoProject.conforms(to: .json))
    }

    @Test func fingerprintFollowsARename() throws {
        let folder = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appending(path: "take 1.mov")
        try Data(repeating: 7, count: 4096).write(to: original)
        let source = try MediaSource(url: original, kind: .video, duration: Time(value: 2, timescale: 1), hasAudio: false)
        guard case .found(let here) = source.resolve() else {
            Issue.record("Expected the file at its path, got \(source.resolve())")
            return
        }
        #expect(here.path == original.path)

        let renamed = folder.appending(path: "Interview.mov")
        try FileManager.default.moveItem(at: original, to: renamed)
        #expect(try Fingerprint(of: renamed) == source.fingerprint)
        guard case .moved(let found) = source.resolve() else {
            Issue.record("Expected the bookmark to find the renamed file, got \(source.resolve())")
            return
        }
        #expect(found.resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path)
        #expect(source.findMatch(in: folder)?.lastPathComponent == "Interview.mov")

        var project = Project(editing: source)
        try project.relink(source.id, to: renamed)
        #expect(project.sources[0].resolve() == .found(URL(filePath: renamed.path(percentEncoded: false))))

        try Data(repeating: 8, count: 10).write(to: renamed)
        #expect(project.sources[0].resolve() == .changed(project.sources[0].url))
        try FileManager.default.removeItem(at: renamed)
        #expect(project.sources[0].resolve() == .missing)
    }

    @Test func editInTimelineStartsFromTheFile() {
        let source = MediaSource(name: "a.mov", kind: .video, duration: Time(value: 10, timescale: 1), frameRate: .fps25, hasAudio: true)
        var sized = source
        (sized.width, sized.height) = (1080, 1920)
        let project = Project(editing: sized, range: TimeRange(start: Time(value: 2, timescale: 1), duration: Time(value: 3, timescale: 1)))
        #expect(project.frameRate == .fps25 && project.settings.canvas.aspect == .vertical)
        #expect(project.tracks[0].clips.first?.duration == Time(value: 3, timescale: 1))
        #expect(project.problems.isEmpty)
    }
}
