import AppKit

/// 空閒無組字狀態（未輸入任何音節或待確認字元）
final class EmptyState: IMEState {
    let name = "EmptyState"
    
    init() {}
    
    func handle(event: NSEvent, context: IMEStateContext) -> StateHandlingResult {
        // 若帶有 Command、Control、Option 等非輸入型修飾鍵，直接 passThrough 給系統或前景應用
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if !modifiers.intersection([.command, .control, .option]).isEmpty {
            return .passThrough
        }
        
        // 數字鍵盤、箭頭等在無組字狀態下直接透傳
        if event.modifierFlags.contains(.numericPad) {
            return .passThrough
        }
        
        return .passThrough
    }
}
