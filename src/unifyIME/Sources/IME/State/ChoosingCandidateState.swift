import AppKit

/// 選字狀態（候選窗已開啟，支援數字鍵選字、方向鍵移動、翻頁等）
final class ChoosingCandidateState: IMEState {
    let name = "ChoosingCandidateState"
    
    init() {}
    
    func onEnter(context: IMEStateContext) {
        context.showCandidateWindow()
    }
    
    func onExit(context: IMEStateContext) {
        context.hideCandidateWindow()
    }
    
    func handle(event: NSEvent, context: IMEStateContext) -> StateHandlingResult {
        switch Int(event.keyCode) {
        case 53: // Escape: 關閉候選窗，退回行內組字狀態
            return .handled(nextState: ComposingState())
            
        case 36, 76: // Enter: 確認目前候選字並提交
            context.confirmSelectedCandidate()
            if context.isComposing {
                return .handled(nextState: ComposingState())
            } else {
                return .handled(nextState: EmptyState())
            }
            
        case 49: // Space: 確認目前候選字
            context.confirmSelectedCandidate()
            if context.isComposing {
                return .handled(nextState: ComposingState())
            } else {
                return .handled(nextState: EmptyState())
            }
            
        case 126: // Up Arrow: 上一個候選字
            let total = context.candidateList.count
            if total > 0 {
                let prev = context.currentCandidateIndex > 0 ? (context.currentCandidateIndex - 1) : (total - 1)
                context.selectCandidate(at: prev)
            }
            return .handled(nextState: nil)
            
        case 125: // Down Arrow: 下一個候選字
            let total = context.candidateList.count
            if total > 0 {
                let next = (context.currentCandidateIndex + 1) % total
                context.selectCandidate(at: next)
            }
            return .handled(nextState: nil)
            
        case 18, 19, 20, 21, 23, 22, 26, 28, 25: // 數字鍵 1~9 直接選字
            let numMap: [Int: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
            if let index = numMap[Int(event.keyCode)], index < context.candidateList.count {
                context.selectCandidate(at: index)
                context.confirmSelectedCandidate()
                if context.isComposing {
                    return .handled(nextState: ComposingState())
                } else {
                    return .handled(nextState: EmptyState())
                }
            }
            return .handled(nextState: nil)
            
        default:
            return .passThrough
        }
    }
}
