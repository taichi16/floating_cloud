import AppKit

/// 行內組字狀態（正在輸入音節、顯示下劃線 Marked Text、即時分析整句）
final class ComposingState: IMEState {
    let name = "ComposingState"
    
    init() {}
    
    func onEnter(context: IMEStateContext) {
        // 進入組字狀態時，確保候選窗處於關閉狀態
        if context.isCandidateWindowOpen {
            context.hideCandidateWindow()
        }
    }
    
    func handle(event: NSEvent, context: IMEStateContext) -> StateHandlingResult {
        // 修飾鍵檢查：若使用者在組字中按下 Cmd+C / Cmd+V 等，應先提交組字再交由系統 passThrough
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if !modifiers.intersection([.command, .control]).isEmpty {
            context.commitCurrentComposition(reason: "shortcutInterruption")
            return .handled(nextState: EmptyState())
        }
        
        switch Int(event.keyCode) {
        case 53: // Escape: 撤銷上一步或清空組字
            _ = context.restorePreviousStep()
            return .handled(nextState: context.isComposing ? nil : EmptyState())
            
        case 123: // Left Arrow: 向左移動組字游標
            _ = context.moveCursor(delta: -1)
            return .handled(nextState: nil)
            
        case 124: // Right Arrow: 向右移動組字游標
            _ = context.moveCursor(delta: 1)
            return .handled(nextState: nil)
            
        case 115: // Home: 移動游標至組字開頭
            _ = context.moveCursorToBoundary(toEnd: false)
            return .handled(nextState: nil)
            
        case 119: // End: 移動游標至組字末尾
            _ = context.moveCursorToBoundary(toEnd: true)
            return .handled(nextState: nil)
            
        case 125, 126: // Down Arrow / Up Arrow: 開啟候選窗選字
            let opened = context.openCandidateWindow()
            if opened {
                return .handled(nextState: ChoosingCandidateState())
            }
            return .handled(nextState: nil)
            
        case 49: // Space: 詞邊界斷詞或選字確認
            _ = context.handleSpaceInComposition()
            return .handled(nextState: context.isComposing ? nil : EmptyState())
            
        case 36, 76: // Enter: 確認目前組字整句提交
            context.commitCurrentComposition(reason: "handle(enter)")
            return .handled(nextState: EmptyState())
            
        case 51: // Backspace: 刪除游標前一個音節或字元
            _ = context.deleteBackward()
            return .handled(nextState: context.isComposing ? nil : EmptyState())
            
        case 117: // Forward Delete: 刪除游標後一個音節或字元
            _ = context.deleteForward()
            return .handled(nextState: context.isComposing ? nil : EmptyState())
            
        default:
            // 字母、注音、符號等輸入交由 Strangler Fig 管道進行映射處理
            return .passThrough
        }
    }
}
