import Foundation
import HermesCaptureProtocol
import Observation

/// What the menu bar shows about the assistant: the current run, its last line, and the
/// trace tail. Fed by the session controller.
@MainActor
@Observable
final class AssistantStatus {
    static let shared = AssistantStatus()
    static let traceLimit = 40

    private(set) var phase: AssistantRunPhase = .idle
    private(set) var instructionText: String?
    private(set) var lastLine: String?
    private(set) var trace: [AgentTraceEvent] = []
    var stopRequest: (@MainActor () -> Void)?

    var isActive: Bool { phase.isActive }

    var statusLine: String {
        switch phase {
        case .idle: "Assistant idle"
        case let .running(step, of): "Assistant working, step \(step) of \(of)"
        case .paused: "Assistant paused"
        case .waitingApproval: "Assistant waiting for approval on the phone"
        case .waitingAnswer: "Assistant waiting for an answer on the phone"
        case let .finished(summary): "Assistant finished: \(summary)"
        case let .failed(reason): "Assistant stopped: \(reason)"
        case .stopped: "Assistant stopped"
        }
    }

    func began(_ instruction: AgentInstruction) {
        instructionText = instruction.text
        trace.removeAll()
        lastLine = nil
    }

    func update(phase: AssistantRunPhase) {
        self.phase = phase
    }

    func record(_ event: AgentTraceEvent) {
        lastLine = event.summary
        trace.append(event)
        if trace.count > Self.traceLimit { trace.removeFirst(trace.count - Self.traceLimit) }
    }

    func reset() {
        phase = .idle
        instructionText = nil
        lastLine = nil
        trace.removeAll()
        stopRequest = nil
    }
}
