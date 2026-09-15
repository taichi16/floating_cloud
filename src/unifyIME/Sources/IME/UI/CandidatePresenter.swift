import AppKit
import InputMethodKit

/// 候選窗呈現與標記文本（Marked Text）視覺渲染器
final class CandidatePresenter {
    static let shared = CandidatePresenter()
    
    private init() {}
    
    /// 產生行內組字下劃線富文本
    func visibleMarkedText(for text: String) -> NSAttributedString {
        let rendered = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        )
        return rendered
    }
    
    /// 計算視覺游標在分段組字中的真實顯示位移
    func displayCursorLocation(forInsertionIndex insertionIndex: Int, segments: [ComposedSegment]) -> Int {
        CompositionPresentationBuilder.displayCursorLocation(forInsertionIndex: insertionIndex, segments: segments)
    }
    
    /// 查詢客戶端螢幕幾何座標作為候選窗定位點
    func candidateAnchor(for client: IMKTextInput, cursorIndex: Int) -> CGPoint? {
        IMKClientTransport.shared.candidateAnchor(for: client, cursorIndex: cursorIndex)
    }
    
    /// 取得目前客戶端的 Marked Range
    func currentMarkedRange(for client: IMKTextInput) -> NSRange {
        IMKClientTransport.shared.currentMarkedRange(for: client)
    }
}
