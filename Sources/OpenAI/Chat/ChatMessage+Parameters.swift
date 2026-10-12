import Foundation

extension ChatMessage {
    /// Projects server output into assistant input, omitting response-only audio bytes and annotations.
    public func asAssistantMessage() -> ChatMessage {
        let content: ChatContent?
        if self.content == .text("") { content = nil } else { content = self.content }
        return ChatMessage(
            role: role, content: content, toolCalls: toolCalls?.isEmpty == false ? toolCalls : nil,
            functionCall: functionCall, refusal: refusal?.isEmpty == false ? refusal : nil,
            reasoningContent: reasoningContent, audio: audio?["id"].map { ["id": $0] }, reasoning: reasoning)
    }
}
