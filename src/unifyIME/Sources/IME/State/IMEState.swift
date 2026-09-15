import AppKit
import InputMethodKit

/// 狀態處理結果
enum StateHandlingResult {
    /// 事件不被當前狀態處理，直接傳遞給作業系統或前景應用程式
    case passThrough
    /// 事件已被處理，若 nextState 非空則進行狀態轉移
    case handled(nextState: (any IMEState)?)
}

/// 輸入法狀態上下文協議，提供具體狀態訪問核心控制器與模型的能力
protocol IMEStateContext: AnyObject {
    var isComposing: Bool { get }
    var currentComposingText: String { get }
    var candidateList: [CandidateEntry] { get }
    var currentCandidateIndex: Int { get }
    var isCandidateWindowOpen: Bool { get }
    
    func setMarkedText(_ text: String, selectionRange: NSRange)
    func insertText(_ text: String)
    func clearMarkedText()
    
    func showCandidateWindow()
    func hideCandidateWindow()
    func selectCandidate(at index: Int)
    func confirmSelectedCandidate()
    
    func commitCurrentComposition(reason: String)
    func resetComposition()
    
    func restorePreviousStep() -> Bool
    func moveCursor(delta: Int) -> Bool
    func moveCursorToBoundary(toEnd: Bool) -> Bool
    func deleteBackward() -> Bool
    func deleteForward() -> Bool
    func handleSpaceInComposition() -> Bool
    func openCandidateWindow() -> Bool
}

/// 核心狀態介面（State Pattern）
protocol IMEState: AnyObject {
    var name: String { get }
    
    /// 處理鍵盤事件
    func handle(event: NSEvent, context: IMEStateContext) -> StateHandlingResult
    
    /// 進入該狀態時的回調
    func onEnter(context: IMEStateContext)
    
    /// 離開該狀態時的回調
    func onExit(context: IMEStateContext)
}

extension IMEState {
    func onEnter(context: IMEStateContext) {}
    func onExit(context: IMEStateContext) {}
}
