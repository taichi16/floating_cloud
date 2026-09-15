import AppKit

/// 狀態機協調器，統一管理目前狀態的生命週期與狀態跳轉
final class StateMachineCoordinator {
    private(set) var currentState: any IMEState
    private unowned let context: IMEStateContext
    
    init(initialState: any IMEState = EmptyState(), context: IMEStateContext) {
        self.currentState = initialState
        self.context = context
        self.currentState.onEnter(context: context)
    }
    
    /// 派發按鍵事件至當前狀態
    func dispatch(event: NSEvent) -> Bool {
        let result = currentState.handle(event: event, context: context)
        switch result {
        case .passThrough:
            return false
        case .handled(let nextState):
            if let next = nextState {
                transition(to: next)
            }
            return true
        }
    }
    
    /// 執行狀態跳轉
    func transition(to newState: any IMEState) {
        guard currentState.name != newState.name else { return }
        currentState.onExit(context: context)
        currentState = newState
        currentState.onEnter(context: context)
    }
    
    /// 重置至空閒初始狀態
    func reset() {
        transition(to: EmptyState())
    }
}
