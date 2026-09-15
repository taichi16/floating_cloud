import Foundation

/// 候選窗 UI 狀態
struct CandidateUIState {
    var isWindowRequested = false
    var lockedCursorLocation: Int?
}

/// 組字編輯歷史快照
struct CompositionUndoSnapshot {
    let readings: [String]
    let trailingReadings: [String]
    let currentReading: String
    let compositionCursorIndex: Int?
    let rawReadingSymbols: [String]
    let rawInputTokens: [String]
    let selectedCandidateEntryHint: CandidateEntry?
    let selectedCandidateIndex: Int
    let candidateMode: Bool
    let candidateUI: CandidateUIState
    let segmentOverrides: [CompositionSegmentKey: String]
    let explicitLockedKeys: Set<CompositionSegmentKey>
    let previewSegmentOverrides: [CompositionSegmentKey: String]
    let mergedCompositionActive: Bool
    let detectedEnglishCandidates: [(rawStart: Int, rawEnd: Int, text: String)]
    let targetState: MultiTargetCompositionState
    let replayedRawTokenCount: Int
    let rawReplayBaseline: MultiTargetCompositionState
    let cachedRawInputBuffer: String?
}

/// 組字歷史快照管理器，提供上限保護與撤銷支援
final class CompositionSnapshotManager {
    private var stack: [CompositionUndoSnapshot] = []
    let maxDepth: Int
    
    init(maxDepth: Int = 128) {
        self.maxDepth = maxDepth
    }
    
    var count: Int {
        stack.count
    }
    
    var canUndo: Bool {
        !stack.isEmpty
    }
    
    func push(_ snapshot: CompositionUndoSnapshot) {
        stack.append(snapshot)
        if stack.count > maxDepth {
            stack.removeFirst(stack.count - maxDepth)
        }
    }
    
    func pop() -> CompositionUndoSnapshot? {
        stack.popLast()
    }
    
    func clear() {
        stack.removeAll(keepingCapacity: false)
    }
}
