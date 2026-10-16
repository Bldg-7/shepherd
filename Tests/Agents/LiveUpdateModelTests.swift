import Foundation

/// The subscription request, the lines herdr writes on a subscription, and
/// when a monitor reads a snapshot. No herdr, no socket, no waiting: times
/// are made up.
@main struct LiveUpdateModelTests {
    static func check(_ value: Bool, _ name: String) {
        precondition(value, name)
        print("PASS: " + name)
    }

    static func main() throws {
        subscriptionRequest()
        streamLines()
        acknowledgement()
        try lineBuffer()
        schedule()
        failures()
    }

    // MARK: The request

    static func subscriptionRequest() {
        let subscription = HerdrChangeSubscription(statusOf: ["w2:p1", "w1:p3", "w1:p1"])
        check(subscription.statusPaneIDs == ["w1:p1", "w1:p3", "w2:p1"], "request: status panes sorted")
        check(subscription == HerdrChangeSubscription(statusOf: ["w1:p1", "w2:p1", "w1:p3"]), "request: equal for the same panes in any order")
        guard let rows = subscription.params["subscriptions"]?.arrayValue else {
            return check(false, "request: params hold a subscriptions array")
        }
        let lifecycle = ["workspace.created", "workspace.updated", "workspace.renamed", "workspace.closed",
                         "workspace.moved", "workspace.reordered",
                         "tab.created", "tab.closed", "tab.renamed", "tab.moved",
                         "pane.created", "pane.closed", "pane.updated", "pane.moved", "pane.exited",
                         "pane.agent_detected", "layout.updated"]
        check(rows.count == 17 + 3, "request: 17 lifecycle subscriptions and one per status pane")
        check(rows.prefix(17).map { $0["type"]?.stringValue } == lifecycle, "request: the 17 lifecycle events, in order")
        check(rows.prefix(17).allSatisfy { $0["pane_id"] == nil }, "request: lifecycle subscriptions are for every pane")
        check(rows.suffix(3).map { $0["type"]?.stringValue } == Array(repeating: "pane.agent_status_changed", count: 3), "request: status subscriptions")
        check(rows.suffix(3).map { $0["pane_id"]?.stringValue } == ["w1:p1", "w1:p3", "w2:p1"], "request: one status subscription per pane")
        check(!lifecycle.contains { $0.contains("focus") || $0.contains("metadata") }, "request: no focus or metadata events")

        let none = HerdrChangeSubscription(statusOf: [])
        check(none.params["subscriptions"]?.arrayValue?.count == 17, "request: lifecycle only without agent panes")

        // The whole request line, as the transports send it.
        let line = try! HerdrRequest(id: "req_7", method: "events.subscribe", params: subscription.params).encodedLine()
        check(line.last == 0x0A && !line.dropLast().contains(0x0A), "request: one line, newline-terminated")
        let decoded = try! JSONDecoder().decode(JSONValue.self, from: line.dropLast())
        check(decoded["method"]?.stringValue == "events.subscribe" && decoded["id"]?.stringValue == "req_7", "request: events.subscribe with its id")
        check(decoded["params"]?["subscriptions"]?.arrayValue?.count == 20, "request: params as built")
    }

    // MARK: Lines

    /// The lines as herdr 0.9.0 (the user's server) and 0.9.1 (a test
    /// server) sent them on 2026-10-16, with paths and titles made up, and
    /// `events_lost` as herdr 0.9.4's source and tests write it.
    static let acknowledgementLine = #"{"id":"req_0","result":{"type":"subscription_started"}}"#
    static let paneUpdatedLine = #"{"event":"pane_updated","data":{"type":"pane_updated","pane":{"agent_status":"unknown","cwd":"/Users/example/project","focused":false,"foreground_cwd":"/Users/example/project","pane_id":"w1:p1","revision":12,"scroll":{"max_offset_from_bottom":40,"offset_from_bottom":0,"viewport_rows":63},"tab_id":"w1:t1","terminal_id":"term_0123456789abcd","terminal_title":"Example title","terminal_title_stripped":"Example title","workspace_id":"w1"}}}"#
    static let statusLine = #"{"event":"pane.agent_status_changed","data":{"agent":"claude","agent_status":"done","pane_id":"w1:p1","workspace_id":"w1"}}"#
    static let detectedLine = #"{"event":"pane_agent_detected","data":{"type":"pane_agent_detected","pane_id":"w1:p2","workspace_id":"w1","agent":"probe"}}"#
    static let paneNotFoundLine = #"{"id":"phase4:sub:1:probe","error":{"code":"pane_not_found","message":"pane nope:p9 not found"}}"#
    static let eventsLostLine = #"{"id":"req_3","error":{"code":"events_lost","message":"event subscription fell behind retained history; resubscribe and resync with session.snapshot"}}"#

    static func line(_ text: String) -> HerdrStreamLine {
        HerdrStreamLine(Data(text.utf8))
    }

    static func streamLines() {
        check(line(acknowledgementLine) == .started, "line: acknowledgement")
        check(line(paneUpdatedLine) == .change("pane_updated"), "line: lifecycle event (pane_updated)")
        check(line(statusLine) == .change("pane.agent_status_changed"), "line: status event (pane.agent_status_changed)")
        check(line(detectedLine) == .change("pane_agent_detected"), "line: pane_agent_detected")
        check(line(paneNotFoundLine) == .failure(code: "pane_not_found", message: "pane nope:p9 not found"), "line: pane_not_found with a probe id")
        if case .failure(let code, _) = line(eventsLostLine) {
            check(code == "events_lost", "line: events_lost (0.9.2+)")
        } else {
            check(false, "line: events_lost (0.9.2+)")
        }
        check(line(#"{"event":"pane_some_future_kind","data":{}}"#) == .change("pane_some_future_kind"), "line: an event of an unknown kind is still a change")
        check(line(#"{"id":"req_1","result":{"type":"ok"}}"#) == .unrecognized, "line: another result is not the acknowledgement")
        check(line(#"{"data":{}}"#) == .unrecognized, "line: no event name")
        check(line(#"{"event":"","data":{}}"#) == .unrecognized, "line: empty event name")
        check(line("not json") == .unrecognized, "line: not JSON")
        check(line(#"{"error":{}}"#) == .failure(code: nil, message: ""), "line: an error without code or message")
    }

    static func acknowledgement() {
        func outcome(_ first: String?) -> (any Error)? {
            do {
                try HerdrStreamLine.checkAcknowledgement(first.map { Data($0.utf8) })
                return nil
            } catch {
                return error
            }
        }
        check(outcome(acknowledgementLine) == nil, "acknowledgement: subscription_started passes")
        check((outcome(paneNotFoundLine) as? HerdrErrorPayload)?.code == "pane_not_found", "acknowledgement: herdr's error is thrown as HerdrErrorPayload")
        check((outcome(#"{"id":"req_0","error":{"code":"invalid_request","message":"bad"}}"#) as? HerdrErrorPayload)?.code == "invalid_request", "acknowledgement: any other refusal too")
        if case .noAcknowledgement? = outcome(nil) as? HerdrSubscriptionError {
            check(true, "acknowledgement: a connection closed first")
        } else {
            check(false, "acknowledgement: a connection closed first")
        }
        if case .noAcknowledgement? = outcome(statusLine) as? HerdrSubscriptionError {
            check(true, "acknowledgement: an event before it")
        } else {
            check(false, "acknowledgement: an event before it")
        }
    }

    static func lineBuffer() throws {
        var buffer = HerdrLineBuffer()
        let text = acknowledgementLine + "\n" + paneUpdatedLine + "\n" + statusLine + "\n"
        let bytes = Array(text.utf8)
        // Split across chunks at awkward places: inside the first line,
        // right after a newline, and inside the last.
        let cuts = [10, acknowledgementLine.utf8.count + 1, bytes.count - 5]
        var lines: [Data] = []
        var start = 0
        for cut in cuts + [bytes.count] {
            lines += try buffer.append(bytes[start..<cut])
            start = cut
        }
        check(lines.map { String(decoding: $0, as: UTF8.self) } == [acknowledgementLine, paneUpdatedLine, statusLine], "buffer: lines split across chunks")

        var whole = HerdrLineBuffer()
        let all = try whole.append(Array(text.utf8))
        check(all.count == 3, "buffer: several lines in one chunk")

        var partial = HerdrLineBuffer()
        check(try partial.append(Array("{\"event\":".utf8)).isEmpty, "buffer: nothing until a newline")
        check(try partial.append(Array("\"x\"}\n\n\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == [#"{"event":"x"}"#], "buffer: blank lines skipped")

        var long = HerdrLineBuffer()
        do {
            _ = try long.append([UInt8](repeating: 0x41, count: HerdrLineBuffer.lineLimit + 1))
            check(false, "buffer: a line past the limit")
        } catch HerdrSubscriptionError.lineTooLong {
            check(true, "buffer: a line past the limit")
        }
    }

    // MARK: When to read

    static func schedule() {
        let t0 = ContinuousClock.now
        func t(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }
        var schedule = HerdrRefreshSchedule()
        check(schedule.timing.gather == .milliseconds(100) && schedule.timing.minimumInterval == .milliseconds(500)
              && schedule.timing.idleRefresh == .seconds(25), "schedule: 0.1 s gather, 0.5 s apart, 25 s without events")

        check(schedule.nextSnapshot(now: t0) == t0, "schedule: the first snapshot straight away")
        schedule.snapshotWanted(at: t(0))
        check(schedule.nextSnapshot(now: t0) == t(0), "schedule: wanted after an acknowledgement, without gathering")
        schedule.snapshotStarted(at: t(0))
        schedule.snapshotFinished(at: t(50))
        check(schedule.nextSnapshot(now: t(60)) == t(50) + .seconds(25), "schedule: 25 s after the last one when nothing happens")

        schedule.changed(at: t(1000))
        check(schedule.nextSnapshot(now: t(1000)) == t(1100), "schedule: a change gathers for 0.1 s")
        schedule.changed(at: t(1050))
        schedule.changed(at: t(1090))
        check(schedule.nextSnapshot(now: t(1090)) == t(1100), "schedule: more changes join the first")

        schedule.snapshotStarted(at: t(1100))
        schedule.snapshotFinished(at: t(1150))
        schedule.changed(at: t(1200))
        check(schedule.nextSnapshot(now: t(1200)) == t(1600), "schedule: snapshots at least 0.5 s apart")

        schedule.snapshotStarted(at: t(2000))
        schedule.changed(at: t(2050))
        schedule.snapshotFinished(at: t(2100))
        check(schedule.nextSnapshot(now: t(2100)) == t(2500), "schedule: a change during a read reads again")

        schedule.snapshotStarted(at: t(3000))
        schedule.changed(at: t(2990))
        schedule.snapshotFinished(at: t(3050))
        check(schedule.nextSnapshot(now: t(3050)) == t(3050) + .seconds(25), "schedule: a change from before the read started is in it")

        // A burst: an agent retitling its terminal every 10 ms for 3 s.
        var burst = HerdrRefreshSchedule()
        var reads: [Int] = []
        var reading: Int?
        for ms in stride(from: 0, through: 3000, by: 10) {
            if let started = reading, ms >= started + 40 {
                burst.snapshotFinished(at: t(ms))
                reading = nil
            }
            if ms > 0 { burst.changed(at: t(ms)) }
            if reading == nil && burst.nextSnapshot(now: t(ms)) <= t(ms) {
                burst.snapshotStarted(at: t(ms))
                reads.append(ms)
                reading = ms
            }
        }
        let gaps = zip(reads.dropFirst(), reads).map { $0 - $1 }
        check(reads.count <= 8 && gaps.allSatisfy { $0 >= 500 }, "schedule: a 3 s burst of changes costs a snapshot per 0.5 s (\(reads))")

        check(HerdrRefreshSchedule.needsSubscription(subscribed: nil, agentPanes: []), "resubscribe: none open")
        check(!HerdrRefreshSchedule.needsSubscription(subscribed: [], agentPanes: []), "resubscribe: lifecycle only, no agents")
        check(!HerdrRefreshSchedule.needsSubscription(subscribed: ["w1:p1"], agentPanes: ["w1:p1"]), "resubscribe: same panes")
        check(HerdrRefreshSchedule.needsSubscription(subscribed: ["w1:p1"], agentPanes: ["w1:p1", "w1:p2"]), "resubscribe: an agent started")
        check(HerdrRefreshSchedule.needsSubscription(subscribed: ["w1:p1", "w1:p2"], agentPanes: ["w1:p1"]), "resubscribe: a pane closed")
    }

    static func failures() {
        let t0 = ContinuousClock.now
        func t(_ seconds: Int) -> ContinuousClock.Instant { t0 + .seconds(seconds) }
        var schedule = HerdrRefreshSchedule()
        check(schedule.timing.failureLimit == 3 && schedule.timing.failureWindow == .seconds(60), "failures: 3 within 60 s")
        check(!schedule.subscriptionFailed(at: t(0)), "failures: first")
        check(!schedule.subscriptionFailed(at: t(10)), "failures: second")
        check(schedule.subscriptionFailed(at: t(20)), "failures: the third within 60 s gives up")

        var spread = HerdrRefreshSchedule()
        check(!spread.subscriptionFailed(at: t(0)) && !spread.subscriptionFailed(at: t(30)), "failures: two")
        check(!spread.subscriptionFailed(at: t(70)), "failures: one older than 60 s no longer counts")
        check(spread.subscriptionFailed(at: t(80)), "failures: three within 60 s again")
    }
}
