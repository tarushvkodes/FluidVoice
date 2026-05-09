import Combine
import Foundation

@MainActor
final class CommandModeService: ObservableObject {
    @Published var conversationHistory: [Message] = []
    @Published var isProcessing = false
    @Published var pendingCommand: PendingCommand? = nil
    @Published var currentStep: AgentStep? = nil
    @Published var streamingText: String = "" // Real-time streaming text for UI
    @Published var streamingThinkingText: String = "" // Real-time thinking tokens for UI
    @Published private(set) var currentChatID: String?
    @Published private(set) var mcpEnabledServerCount: Int = 0
    @Published private(set) var mcpConnectedServerCount: Int = 0
    @Published private(set) var mcpLastError: String?
    @Published private(set) var isMCPBootstrapInProgress: Bool = false

    private let terminalService = TerminalService()
    private let mcpManager = MCPManager.shared
    private let chatStore = ChatHistoryStore.shared
    private var currentTurnCount = 0
    private let maxTurns = 20
    private var didRequireConfirmationThisRun: Bool = false
    private var isMCPSessionInitialized: Bool = false
    private var cachedMCPTools: [[String: Any]] = []
    private var mcpBootstrapTask: Task<Void, Never>?
    private let mcpBootstrapWaitTimeoutNs: UInt64 = 200_000_000
    private var pendingCommandQueue: [PendingCommand] = []

    // Flag to enable notch output display
    var enableNotchOutput: Bool = true

    // Streaming UI update throttling - adaptive rate based on content length
    private var lastUIUpdate: CFAbsoluteTime = 0
    private var lastThinkingUIUpdate: CFAbsoluteTime = 0
    private var lastNotchStreamingUIUpdate: CFAbsoluteTime = 0
    private let notchStreamingUpdateInterval: CFAbsoluteTime = 0.05
    private var streamingBuffer: [String] = [] // Buffer tokens instead of string concat
    private var thinkingBuffer: [String] = [] // Buffer thinking tokens

    // MARK: - Initialization

    init() {
        // Load current chat from store
        self.loadCurrentChatFromStore()
        self.startMCPSessionBootstrapIfNeeded()
    }

    private var shouldSyncCommandNotchState: Bool {
        self.enableNotchOutput && NotchOverlayManager.shared.shouldSyncCommandConversationToNotch
    }

    private func loadCurrentChatFromStore() {
        if let session = chatStore.currentSession {
            self.currentChatID = session.id
            self.conversationHistory = session.messages.map { self.chatMessageToMessage($0) }
            self.syncToNotchState()
        } else {
            // Create new chat if none exists
            let newSession = self.chatStore.createNewChat()
            self.currentChatID = newSession.id
            self.conversationHistory = []
        }
    }

    // MARK: - Agent Step Tracking

    enum AgentStep: Equatable {
        case thinking(String)
        case checking(String)
        case executing(String)
        case verifying(String)
        case completed(Bool)
    }

    // MARK: - Models

    struct Message: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        let content: String
        let thinking: String? // Display-only: AI reasoning tokens (NOT sent to API)
        let toolCall: ToolCall?
        let stepType: StepType
        let renderIntent: RenderIntent
        let sourceToolCallID: String?
        let timestamp: Date

        enum Role: Equatable {
            case user
            case assistant
            case tool
        }

        enum RenderIntent: String, Equatable {
            case userText
            case assistantText
            case toolInvocation
            case toolResult
            case status
        }

        enum StepType: Equatable {
            case normal
            case thinking // AI reasoning
            case checking // Pre-flight verification
            case executing // Running command
            case verifying // Post-action check
            case success // Action completed
            case failure // Action failed
        }

        struct ToolCall: Equatable {
            let id: String
            let toolName: String
            let argumentsJSON: String
            let command: String?
            let workingDirectory: String?
            let purpose: String? // Why this command is being run

            var isTerminalCommand: Bool {
                self.toolName == "execute_terminal_command"
            }
        }

        init(
            role: Role,
            content: String,
            thinking: String? = nil,
            toolCall: ToolCall? = nil,
            stepType: StepType = .normal,
            renderIntent: RenderIntent? = nil,
            sourceToolCallID: String? = nil
        ) {
            self.role = role
            self.content = content
            self.thinking = thinking
            self.toolCall = toolCall
            self.stepType = stepType
            self.renderIntent =
                renderIntent ?? Self.defaultRenderIntent(for: role, toolCall: toolCall)
            self.sourceToolCallID = sourceToolCallID
            self.timestamp = Date()
        }

        private static func defaultRenderIntent(for role: Role, toolCall: ToolCall?) -> RenderIntent {
            switch role {
            case .user:
                return .userText
            case .tool:
                return .toolResult
            case .assistant:
                return toolCall == nil ? .assistantText : .toolInvocation
            }
        }
    }

    struct PendingCommand {
        enum ToolKind {
            case terminal
            case mcp
        }

        let kind: ToolKind
        let id: String
        let toolName: String
        let arguments: [String: Any]
        let argumentsJSON: String
        let command: String?
        let workingDirectory: String?
        let purpose: String?

        var isTerminalCommand: Bool {
            self.kind == .terminal
        }

        static func terminal(
            id: String,
            command: String,
            workingDirectory: String?,
            purpose: String?
        ) -> PendingCommand {
            PendingCommand(
                kind: .terminal,
                id: id,
                toolName: "execute_terminal_command",
                arguments: [:],
                argumentsJSON: "{}",
                command: command,
                workingDirectory: workingDirectory,
                purpose: purpose
            )
        }

        static func mcp(
            id: String,
            toolName: String,
            arguments: [String: Any],
            argumentsJSON: String
        ) -> PendingCommand {
            PendingCommand(
                kind: .mcp,
                id: id,
                toolName: toolName,
                arguments: arguments,
                argumentsJSON: argumentsJSON,
                command: nil,
                workingDirectory: nil,
                purpose: nil
            )
        }
    }

    // MARK: - Public Methods

    func clearHistory() {
        self.conversationHistory.removeAll()
        self.pendingCommand = nil
        self.pendingCommandQueue.removeAll()
        self.currentTurnCount = 0

        // Clear in store as well
        self.chatStore.clearCurrentChat()

        // Also clear notch state
        NotchContentState.shared.clearCommandOutput()
    }

    func refreshMCPStatus() async {
        self.startMCPSessionBootstrapIfNeeded()
        _ = await self.waitForMCPBootstrapIfNeeded(
            timeoutNanoseconds: self.mcpBootstrapWaitTimeoutNs)
        if self.isMCPSessionInitialized {
            await self.updateMCPStatusAndToolCache()
        }
    }

    func reloadMCPConfiguration() async {
        self.mcpBootstrapTask?.cancel()
        self.mcpBootstrapTask = nil
        await self.runMCPBootstrap(forceReload: true)
    }

    func mcpSettingsFileURL() async -> URL? {
        await self.mcpManager.settingsFileURL()
    }

    func loadMCPSettingsJSON() async throws -> String {
        try await self.mcpManager.loadSettingsJSON()
    }

    func validateMCPSettingsJSON(_ json: String) async throws {
        try await self.mcpManager.validateSettingsJSON(json)
    }

    func saveMCPSettingsJSONAndReload(_ json: String) async throws {
        try await self.mcpManager.saveSettingsJSON(json)
        await self.reloadMCPConfiguration()
    }

    private func startMCPSessionBootstrapIfNeeded() {
        if self.isMCPSessionInitialized || self.mcpBootstrapTask != nil {
            return
        }

        DebugLogger.shared.debug("Starting background MCP bootstrap", source: "CommandModeService")
        self.isMCPBootstrapInProgress = true
        self.mcpBootstrapTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.runMCPBootstrap(forceReload: false)
            self.mcpBootstrapTask = nil
        }
    }

    private func runMCPBootstrap(forceReload: Bool) async {
        self.isMCPBootstrapInProgress = true
        self.isMCPSessionInitialized = false

        if Task.isCancelled {
            DebugLogger.shared.debug(
                "MCP bootstrap cancelled before reload", source: "CommandModeService"
            )
            self.isMCPBootstrapInProgress = false
            return
        }

        await self.mcpManager.reloadConfiguration(force: forceReload)

        if Task.isCancelled {
            DebugLogger.shared.debug(
                "MCP bootstrap cancelled after reload", source: "CommandModeService"
            )
            self.isMCPBootstrapInProgress = false
            return
        }

        self.isMCPSessionInitialized = true
        await self.updateMCPStatusAndToolCache()
        DebugLogger.shared.info(
            "MCP bootstrap completed (enabled=\(self.mcpEnabledServerCount), connected=\(self.mcpConnectedServerCount), tools=\(self.cachedMCPTools.count), forced=\(forceReload))",
            source: "CommandModeService"
        )
        self.isMCPBootstrapInProgress = false
    }

    private func waitForMCPBootstrapIfNeeded(timeoutNanoseconds: UInt64) async -> Bool {
        guard let bootstrapTask = self.mcpBootstrapTask else {
            return self.isMCPSessionInitialized
        }

        let finishedWithinTimeout = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await bootstrapTask.value
                return true
            }

            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    return false
                } catch {
                    return true
                }
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        if finishedWithinTimeout {
            self.mcpBootstrapTask = nil
        }

        return self.isMCPSessionInitialized
    }

    private func updateMCPStatusAndToolCache() async {
        self.cachedMCPTools = await self.mcpManager.toolDefinitions(reloadIfNeeded: false)

        let summary = await self.mcpManager.statusSummary(reloadIfNeeded: false)
        self.mcpEnabledServerCount = summary.enabledServers
        self.mcpConnectedServerCount = summary.connectedServers
        self.mcpLastError = summary.lastError
    }

    // MARK: - Chat Management

    /// Get recent chats for dropdown
    func getRecentChats() -> [ChatSession] {
        return self.chatStore.getRecentChats(excludingCurrent: false)
    }

    /// Create a new chat and switch to it
    func createNewChat() {
        // Can't switch while processing
        guard !self.isProcessing else { return }

        // Save current chat first
        self.saveCurrentChat()

        // Create new
        let newSession = self.chatStore.createNewChat()
        self.currentChatID = newSession.id
        self.conversationHistory = []
        self.pendingCommand = nil
        self.pendingCommandQueue.removeAll()
        self.currentTurnCount = 0
        self.currentStep = nil

        // Clear notch state
        NotchContentState.shared.clearCommandOutput()
        NotchContentState.shared.refreshRecentChats()
    }

    /// Switch to a different chat by ID
    /// Returns false if switching is blocked (e.g., during processing)
    @discardableResult
    func switchToChat(id: String) -> Bool {
        // Can't switch while processing
        guard !self.isProcessing else { return false }

        // Don't switch to current
        guard id != self.currentChatID else { return true }

        // Save current chat first
        self.saveCurrentChat()

        // Load the target chat
        guard let session = chatStore.switchToChat(id: id) else { return false }

        self.currentChatID = session.id
        self.conversationHistory = session.messages.map { self.chatMessageToMessage($0) }
        self.pendingCommand = nil
        self.pendingCommandQueue.removeAll()
        self.currentTurnCount = 0
        self.currentStep = nil

        // Sync to notch state
        self.syncToNotchState()
        NotchContentState.shared.refreshRecentChats()

        return true
    }

    /// Delete current chat and switch to next
    func deleteCurrentChat() {
        // Can't delete while processing
        guard !self.isProcessing else { return }

        self.chatStore.deleteCurrentChat()

        // Load the new current chat
        self.loadCurrentChatFromStore()
        NotchContentState.shared.refreshRecentChats()
    }

    /// Save current conversation to store
    func saveCurrentChat() {
        guard self.currentChatID != nil else { return }

        let messages = self.conversationHistory.map { self.messageToChatMessage($0) }
        self.chatStore.updateCurrentChat(messages: messages)
    }

    // MARK: - Conversion Helpers

    private func messageToChatMessage(_ msg: Message) -> ChatMessage {
        let role: ChatMessage.Role
        switch msg.role {
        case .user: role = .user
        case .assistant: role = .assistant
        case .tool: role = .tool
        }

        let renderIntent =
            ChatMessage.RenderIntent(rawValue: msg.renderIntent.rawValue) ?? .assistantText

        let stepType: ChatMessage.StepType
        switch msg.stepType {
        case .normal: stepType = .normal
        case .thinking: stepType = .thinking
        case .checking: stepType = .checking
        case .executing: stepType = .executing
        case .verifying: stepType = .verifying
        case .success: stepType = .success
        case .failure: stepType = .failure
        }

        var toolCall: ChatMessage.ToolCall? = nil
        if let tc = msg.toolCall {
            toolCall = ChatMessage.ToolCall(
                id: tc.id,
                toolName: tc.toolName,
                argumentsJSON: tc.argumentsJSON,
                command: tc.command,
                workingDirectory: tc.workingDirectory,
                purpose: tc.purpose
            )
        }

        return ChatMessage(
            id: msg.id,
            role: role,
            content: msg.content,
            toolCall: toolCall,
            stepType: stepType,
            renderIntent: renderIntent,
            sourceToolCallID: msg.sourceToolCallID,
            timestamp: msg.timestamp
        )
    }

    private func chatMessageToMessage(_ chatMsg: ChatMessage) -> Message {
        let role: Message.Role
        switch chatMsg.role {
        case .user: role = .user
        case .assistant: role = .assistant
        case .tool: role = .tool
        }

        let renderIntent =
            Message.RenderIntent(rawValue: chatMsg.renderIntent.rawValue) ?? .assistantText

        let stepType: Message.StepType
        switch chatMsg.stepType {
        case .normal: stepType = .normal
        case .thinking: stepType = .thinking
        case .checking: stepType = .checking
        case .executing: stepType = .executing
        case .verifying: stepType = .verifying
        case .success: stepType = .success
        case .failure: stepType = .failure
        }

        var toolCall: Message.ToolCall? = nil
        if let tc = chatMsg.toolCall {
            toolCall = Message.ToolCall(
                id: tc.id,
                toolName: tc.toolName,
                argumentsJSON: tc.argumentsJSON,
                command: tc.command,
                workingDirectory: tc.workingDirectory,
                purpose: tc.purpose
            )
        }

        return Message(
            role: role,
            content: chatMsg.content,
            toolCall: toolCall,
            stepType: stepType,
            renderIntent: renderIntent,
            sourceToolCallID: chatMsg.sourceToolCallID
        )
    }

    /// Sync conversation history to NotchContentState
    private func syncToNotchState() {
        guard self.shouldSyncCommandNotchState else {
            return
        }

        NotchContentState.shared.clearCommandOutput()

        for msg in self.conversationHistory {
            switch msg.renderIntent {
            case .userText:
                guard !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                NotchContentState.shared.addCommandMessage(role: .user, content: msg.content)
            case .assistantText:
                guard !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                NotchContentState.shared.addCommandMessage(role: .assistant, content: msg.content)
            case .status:
                guard !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                NotchContentState.shared.addCommandMessage(role: .status, content: msg.content)
            case .toolInvocation:
                let statusText = self.notchStatusText(for: msg)
                guard !statusText.isEmpty else { continue }
                NotchContentState.shared.addCommandMessage(role: .status, content: statusText)
            case .toolResult:
                continue
            }
        }
    }

    private func notchStatusText(for message: Message) -> String {
        if let purpose = message.toolCall?.purpose?.trimmingCharacters(in: .whitespacesAndNewlines),
           !purpose.isEmpty
        {
            return purpose
        }

        if let tc = message.toolCall {
            if tc.isTerminalCommand {
                if let command = tc.command?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !command.isEmpty
                {
                    return "Running: \(self.truncateStatusText(command, limit: 80))"
                }

                let defaultStatus = self.stepDescription(for: message.stepType)
                return defaultStatus.isEmpty ? "Running command..." : defaultStatus
            }

            return "Calling MCP tool: \(tc.toolName)"
        }

        return message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func truncateStatusText(_ text: String, limit: Int) -> String {
        if text.count <= limit {
            return text
        }
        return String(text.prefix(limit - 1)) + "..."
    }

    /// Process user voice/text command
    func processUserCommand(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        self.isProcessing = true
        self.currentTurnCount = 0
        self.didRequireConfirmationThisRun = false
        self.pendingCommandQueue.removeAll()
        self.conversationHistory.append(Message(role: .user, content: text))

        // Auto-save after adding user message
        self.saveCurrentChat()

        // Push to notch
        if self.shouldSyncCommandNotchState {
            NotchContentState.shared.clearCommandTurnBadge()
            NotchContentState.shared.addCommandMessage(role: .user, content: text)
            NotchContentState.shared.setCommandProcessing(true)
        }

        await self.processNextTurn()
    }

    /// Process follow-up command from notch input
    func processFollowUpCommand(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Add to both histories
        self.conversationHistory.append(Message(role: .user, content: text))
        if self.shouldSyncCommandNotchState {
            NotchContentState.shared.addCommandMessage(role: .user, content: text)
        }

        // Auto-save after adding user message
        self.saveCurrentChat()

        self.isProcessing = true
        self.didRequireConfirmationThisRun = false
        if self.shouldSyncCommandNotchState {
            NotchContentState.shared.clearCommandTurnBadge()
            NotchContentState.shared.setCommandProcessing(true)
        }

        await self.processNextTurn()
    }

    /// Execute pending command (after user confirmation)
    func confirmAndExecute() async {
        guard let pending = pendingCommand else { return }
        self.pendingCommand = nil
        self.isProcessing = true

        await self.executePendingCommand(pending, continueAfterExecution: false)
        await self.continueAfterConfirmedCommand()
    }

    /// Cancel pending command
    func cancelPendingCommand() {
        let pending = self.pendingCommand
        let cancellationText =
            pending?.isTerminalCommand == true
                ? "Command cancelled."
                : "Tool call cancelled."
        self.pendingCommand = nil
        self.pendingCommandQueue.removeAll()
        if let pending {
            self.conversationHistory.append(
                Message(
                    role: .tool,
                    content: cancellationText,
                    stepType: .failure,
                    renderIntent: .toolResult,
                    sourceToolCallID: pending.id
                ))
        }
        self.conversationHistory.append(
            Message(
                role: .assistant,
                content: cancellationText,
                stepType: .failure,
                renderIntent: .status
            ))
        self.isProcessing = false
        self.currentStep = nil
    }

    // MARK: - Agent Loop

    private func processNextTurn() async {
        if self.currentTurnCount >= self.maxTurns {
            let errorMsg =
                "Reached maximum steps limit. Please review the progress and continue if needed."
            self.conversationHistory.append(
                Message(
                    role: .assistant,
                    content: errorMsg,
                    stepType: .failure
                ))
            self.isProcessing = false
            self.currentStep = .completed(false)

            // Auto-save on completion
            self.saveCurrentChat()

            self.captureCommandRunCompleted(success: false)

            // Push to notch
            if self.shouldSyncCommandNotchState {
                NotchContentState.shared.addCommandMessage(role: .assistant, content: errorMsg)
                NotchContentState.shared.setCommandProcessing(false)
                self.showCompletionBadgeIfNeeded(success: false)
            }
            return
        }

        self.currentTurnCount += 1
        self.currentStep = .thinking("Analyzing...")

        // Push status to notch
        if self.shouldSyncCommandNotchState {
            NotchContentState.shared.addCommandMessage(role: .status, content: "Thinking...")
        }

        do {
            let response = try await callLLM()

            switch response.turnKind {
            case .toolCallOnly, .toolCallWithText:
                let pendingCalls = response.toolCalls.map { self.pendingCommand(from: $0) }
                await self.executeToolCalls(pendingCalls, response: response)

            case .textOnly, .empty:
                let finalContent =
                    response.normalizedContent.isEmpty
                        ? "I couldn't understand that." : response.normalizedContent

                // Just a text response - infer whether this is a successful completion summary.
                let isFinal = self.isSuccessfulCompletionSummary(finalContent)

                self.conversationHistory.append(
                    Message(
                        role: .assistant,
                        content: finalContent,
                        thinking: response.thinking,
                        stepType: isFinal ? .success : .normal,
                        renderIntent: .assistantText
                    ))
                self.isProcessing = false
                self.currentStep = .completed(isFinal)

                // Auto-save on completion
                self.saveCurrentChat()

                self.captureCommandRunCompleted(success: isFinal)

                // Push final response to notch and show compact completion badge
                if self.shouldSyncCommandNotchState {
                    NotchContentState.shared.updateCommandStreamingText("") // Clear streaming
                    NotchContentState.shared.addCommandMessage(
                        role: .assistant, content: finalContent
                    )
                    NotchContentState.shared.setCommandProcessing(false)
                    self.showCompletionBadgeIfNeeded(success: isFinal)
                }
            }

        } catch {
            let errorMsg = "Error: \(error.localizedDescription)"
            self.conversationHistory.append(
                Message(
                    role: .assistant,
                    content: errorMsg,
                    stepType: .failure
                ))
            self.isProcessing = false
            self.currentStep = .completed(false)

            // Auto-save on error
            self.saveCurrentChat()

            self.captureCommandRunCompleted(success: false)

            // Push error to notch
            if self.shouldSyncCommandNotchState {
                NotchContentState.shared.addCommandMessage(role: .assistant, content: errorMsg)
                NotchContentState.shared.setCommandProcessing(false)
                self.showCompletionBadgeIfNeeded(success: false)
            }
        }
    }

    private func captureCommandRunCompleted(success: Bool) {
        let toolCalls = self.conversationHistory.compactMap { $0.toolCall }.count
        let turns = self.currentTurnCount

        let turnsBucket: String
        switch turns {
        case ...1: turnsBucket = "1"
        case 2...3: turnsBucket = "2-3"
        case 4...7: turnsBucket = "4-7"
        case 8...20: turnsBucket = "8-20"
        default: turnsBucket = "20+"
        }

        let toolCallsBucket: String
        switch toolCalls {
        case 0: toolCallsBucket = "0"
        case 1...2: toolCallsBucket = "1-2"
        case 3...5: toolCallsBucket = "3-5"
        default: toolCallsBucket = "6+"
        }

        AnalyticsService.shared.capture(
            .commandModeRunCompleted,
            properties: [
                "success": success,
                "turns_bucket": turnsBucket,
                "tool_calls_bucket": toolCallsBucket,
                "confirmation_needed": self.didRequireConfirmationThisRun,
            ]
        )
    }

    /// Show compact completion badge in the notch if there's content to display
    private func showCompletionBadgeIfNeeded(success: Bool) {
        guard self.shouldSyncCommandNotchState else { return }
        guard !NotchContentState.shared.commandConversationHistory.isEmpty else { return }

        NotchOverlayManager.shared.showCommandCompletionBadge(success: success)
    }

    private func isSuccessfulCompletionSummary(_ summary: String) -> Bool {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.contains("✗") {
            return false
        }
        if trimmed.contains("✓") || trimmed.contains("✔") {
            return true
        }

        let lowered = trimmed.lowercased()
        let failureKeywords = [
            "failed", "failure", "error", "unable", "cannot", "can't", "could not", "couldn't",
            "not possible", "did not", "didn't",
        ]
        if failureKeywords.contains(where: { lowered.contains($0) }) {
            return false
        }

        let successKeywords = [
            "complete", "completed", "done", "success", "successful", "finished",
        ]
        if successKeywords.contains(where: { lowered.contains($0) }) {
            return true
        }

        // If the model gave a neutral summary, fall back to tool outcomes for this run.
        let toolResults = self.currentRunToolResultMessages()
        if toolResults.contains(where: { $0.stepType == .failure }) {
            return false
        }
        if toolResults.contains(where: { $0.stepType == .success }) {
            return true
        }

        return false
    }

    private func currentRunToolResultMessages() -> [Message] {
        guard let lastUserIndex = self.conversationHistory.lastIndex(where: { $0.role == .user })
        else {
            return []
        }

        let messagesAfterUser = self.conversationHistory.suffix(
            from: self.conversationHistory.index(after: lastUserIndex))
        return messagesAfterUser.filter { $0.role == .tool }
    }

    private func determineStepType(for command: String, purpose: String?) -> Message.StepType {
        let cmd = command.lowercased()
        let purposeLower = purpose?.lowercased() ?? ""

        // Check commands
        if purposeLower.contains("check") || purposeLower.contains("verify")
            || purposeLower.contains("exist")
        {
            return .checking
        }
        if cmd.hasPrefix("ls ") || cmd.hasPrefix("cat ") || cmd.hasPrefix("test ")
            || cmd.hasPrefix("[ ") || cmd.contains("--version") || cmd.contains("which ")
            || cmd.contains("file ") || cmd.hasPrefix("stat ") || cmd.hasPrefix("head ")
            || cmd.hasPrefix("tail ")
        {
            return .checking
        }

        // Verification commands
        if purposeLower.contains("confirm") || purposeLower.contains("result") {
            return .verifying
        }

        return .executing
    }

    private func stepDescription(for stepType: Message.StepType) -> String {
        switch stepType {
        case .checking: return "Checking prerequisites..."
        case .verifying: return "Verifying the result..."
        case .executing: return "Executing command..."
        default: return ""
        }
    }

    private func isDestructiveCommand(_ command: String) -> Bool {
        let cmd = command.lowercased()

        // Commands that start with these are destructive
        let destructivePrefixes = [
            "rm ", "rm\t", "rmdir ", "rm -", // delete
            "mv ", "mv\t", // move/rename
            "sudo ", // elevated privileges
            "kill ", "pkill ", "killall ", // terminate processes
            "chmod ", "chown ", "chgrp ", // change permissions/ownership
            "dd ", // disk operations
            "mkfs", "format", // filesystem formatting
            "> ", // overwrite file
            "truncate ", // truncate file
            "shred ", // secure delete
        ]

        // Check if command starts with any destructive prefix
        if destructivePrefixes.contains(where: { cmd.hasPrefix($0) }) {
            return true
        }

        // Check for destructive patterns anywhere in piped commands
        let destructivePatterns = [
            "| rm ", "| sudo ", "| dd ",
            "; rm ", "; sudo ",
            "&& rm ", "&& sudo ",
            "xargs rm", "xargs -I",
        ]

        if destructivePatterns.contains(where: { cmd.contains($0) }) {
            return true
        }

        // rm with flags like -rf, -r, -f anywhere
        if cmd.contains("rm -") {
            return true
        }

        return false
    }

    private func encodeToolArgumentsJSON(_ arguments: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(
                  withJSONObject: arguments, options: [.sortedKeys]
              ),
              let jsonString = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return jsonString
    }

    private func pendingCommand(from toolCall: LLMResponse.ToolCallData) -> PendingCommand {
        let argsJSON = self.encodeToolArgumentsJSON(toolCall.arguments)
        if toolCall.name == "execute_terminal_command" {
            return PendingCommand(
                kind: .terminal,
                id: toolCall.id,
                toolName: toolCall.name,
                arguments: toolCall.arguments,
                argumentsJSON: argsJSON,
                command: toolCall.getString("command") ?? "",
                workingDirectory: toolCall.getOptionalString("workingDirectory"),
                purpose: toolCall.getString("purpose")
            )
        }

        return .mcp(
            id: toolCall.id,
            toolName: toolCall.name,
            arguments: toolCall.arguments,
            argumentsJSON: argsJSON
        )
    }

    private func appendToolInvocation(
        for pending: PendingCommand,
        content: String,
        thinking: String?
    ) {
        let stepType: Message.StepType
        let stepLabel: String

        switch pending.kind {
        case .terminal:
            let command = pending.command ?? ""
            stepType = self.determineStepType(for: command, purpose: pending.purpose)
            stepLabel = command
        case .mcp:
            stepType = .executing
            stepLabel = pending.toolName
        }

        switch stepType {
        case .checking:
            self.currentStep = .checking(stepLabel)
        case .verifying:
            self.currentStep = .verifying(stepLabel)
        default:
            self.currentStep = .executing(stepLabel)
        }

        let toolMessage = Message(
            role: .assistant,
            content: content,
            thinking: thinking,
            toolCall: Message.ToolCall(
                id: pending.id,
                toolName: pending.toolName,
                argumentsJSON: pending.argumentsJSON,
                command: pending.isTerminalCommand ? pending.command : nil,
                workingDirectory: pending.workingDirectory,
                purpose: pending.purpose
            ),
            stepType: stepType,
            renderIntent: .toolInvocation
        )
        self.conversationHistory.append(toolMessage)

        if self.shouldSyncCommandNotchState {
            let statusText = self.notchStatusText(for: toolMessage)
            if !statusText.isEmpty {
                NotchContentState.shared.addCommandMessage(role: .status, content: statusText)
            }
        }
    }

    private func executeToolCalls(_ pendingCalls: [PendingCommand], response: LLMResponse?) async {
        var remaining = pendingCalls
        var responseContent = response?.normalizedContent ?? ""
        var responseThinking = response?.thinking

        while !remaining.isEmpty {
            let pending = remaining.removeFirst()
            self.appendToolInvocation(
                for: pending,
                content: responseContent,
                thinking: responseThinking
            )
            responseContent = ""
            responseThinking = nil

            if self.requiresConfirmation(for: pending) {
                self.pendingCommandQueue = remaining
                self.presentConfirmation(for: pending)
                return
            }

            await self.executePendingCommand(pending, continueAfterExecution: false)
        }

        await self.processNextTurn()
    }

    private func requiresConfirmation(for pending: PendingCommand) -> Bool {
        guard SettingsStore.shared.commandModeConfirmBeforeExecute else { return false }

        switch pending.kind {
        case .terminal:
            return self.isDestructiveCommand(pending.command ?? "")
        case .mcp:
            return true
        }
    }

    private func presentConfirmation(for pending: PendingCommand) {
        self.didRequireConfirmationThisRun = true
        self.pendingCommand = pending
        self.isProcessing = false
        self.currentStep = nil

        if self.shouldSyncCommandNotchState {
            NotchContentState.shared.addCommandMessage(
                role: .status,
                content: "⚠️ Confirmation needed in Command Mode window"
            )
            NotchContentState.shared.setCommandProcessing(false)
        }
    }

    private func executePendingCommand(
        _ pending: PendingCommand,
        continueAfterExecution: Bool
    ) async {
        switch pending.kind {
        case .terminal:
            guard let command = pending.command else { return }
            await self.executeCommand(
                command,
                workingDirectory: pending.workingDirectory,
                callId: pending.id,
                purpose: pending.purpose,
                continueAfterExecution: continueAfterExecution
            )
        case .mcp:
            await self.executeMCPTool(
                name: pending.toolName,
                arguments: pending.arguments,
                callId: pending.id,
                continueAfterExecution: continueAfterExecution
            )
        }
    }

    private func continueAfterConfirmedCommand() async {
        let queuedCommands = self.pendingCommandQueue
        self.pendingCommandQueue.removeAll()

        if queuedCommands.isEmpty {
            await self.processNextTurn()
        } else {
            await self.executeToolCalls(queuedCommands, response: nil)
        }
    }

    private func executeCommand(
        _ command: String,
        workingDirectory: String?,
        callId: String,
        purpose: String? = nil,
        continueAfterExecution: Bool = true
    ) async {
        self.currentStep = .executing(command)

        let result = await terminalService.execute(
            command: command,
            workingDirectory: workingDirectory
        )

        // Create enhanced result with context
        let enhancedResult = EnhancedCommandResult(
            result: result,
            purpose: purpose
        )

        let resultJSON = enhancedResult.toJSON()

        // Determine result step type
        let resultStepType: Message.StepType = result.success ? .success : .failure

        // Add tool result to conversation
        self.conversationHistory.append(
            Message(
                role: .tool,
                content: resultJSON,
                stepType: resultStepType,
                renderIntent: .toolResult,
                sourceToolCallID: callId
            ))

        if continueAfterExecution {
            await self.processNextTurn()
        }
    }

    private func executeMCPTool(
        name: String,
        arguments: [String: Any],
        callId: String,
        continueAfterExecution: Bool = true
    ) async {
        self.currentStep = .executing(name)

        let startTime = Date()
        let result = await self.mcpManager.callTool(
            functionName: name, arguments: arguments, reloadIfNeeded: false
        )
        let executionTimeMs = Int(Date().timeIntervalSince(startTime) * 1000)

        let enhancedResult = EnhancedMCPToolResult(
            success: result.success,
            toolName: result.toolName,
            serverID: result.serverID,
            output: result.output,
            error: result.error,
            isError: result.isError,
            content: result.content,
            executionTimeMs: executionTimeMs
        )

        let resultJSON = enhancedResult.toJSON()
        let resultStepType: Message.StepType = result.success ? .success : .failure

        self.conversationHistory.append(
            Message(
                role: .tool,
                content: resultJSON,
                stepType: resultStepType,
                renderIntent: .toolResult,
                sourceToolCallID: callId
            ))

        await self.updateMCPStatusAndToolCache()

        if continueAfterExecution {
            await self.processNextTurn()
        }
    }

    // MARK: - Enhanced Result

    private struct EnhancedCommandResult: Codable {
        let success: Bool
        let command: String
        let output: String
        let error: String?
        let exitCode: Int32
        let executionTimeMs: Int
        let purpose: String?

        init(result: TerminalService.CommandResult, purpose: String?) {
            self.success = result.success
            self.command = result.command
            self.output = result.output
            self.error = result.error
            self.exitCode = result.exitCode
            self.executionTimeMs = result.executionTimeMs
            self.purpose = purpose
        }

        func toJSON() -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(self),
               let json = String(data: data, encoding: .utf8)
            {
                return json
            }
            return """
            {"success": \(self.success), "output": "\(self.output)", "exitCode": \(self.exitCode)}
            """
        }
    }

    private struct EnhancedMCPToolResult: Codable {
        let success: Bool
        let toolName: String
        let serverID: String?
        let output: String
        let error: String?
        let isError: Bool
        let content: [MCPManager.ToolExecutionContent]
        let executionTimeMs: Int

        func toJSON() -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(self),
               let json = String(data: data, encoding: .utf8)
            {
                return json
            }
            return "{\"success\":false,\"output\":\"<mcp-result-encode-failed>\",\"exitCode\":-1}"
        }
    }

    // MARK: - LLM Integration

    private struct LLMResponse {
        let content: String
        let thinking: String? // Display-only, NOT sent back to API
        let toolCalls: [ToolCallData]

        enum TurnKind {
            case toolCallOnly
            case toolCallWithText
            case textOnly
            case empty
        }

        var normalizedContent: String {
            self.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var turnKind: TurnKind {
            let hasToolCalls = !self.toolCalls.isEmpty
            let hasText = !self.normalizedContent.isEmpty

            switch (hasToolCalls, hasText) {
            case (true, true): return .toolCallWithText
            case (true, false): return .toolCallOnly
            case (false, true): return .textOnly
            case (false, false): return .empty
            }
        }

        struct ToolCallData {
            let id: String
            let name: String
            let arguments: [String: Any]

            func getString(_ key: String) -> String? {
                self.arguments[key] as? String
            }

            func getOptionalString(_ key: String) -> String? {
                guard let value = self.arguments[key] as? String else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
    }

    private func callLLM() async throws -> LLMResponse {
        let settings = SettingsStore.shared
        // Use Command Mode's independent provider/model settings
        let providerID = settings.commandModeSelectedProviderID
        let model = settings.commandModeSelectedModel ?? "gpt-4.1"
        let apiKey = settings.getAPIKey(for: providerID) ?? ""

        let baseURL: String
        if let provider = settings.savedProviders.first(where: { $0.id == providerID }) {
            baseURL = provider.baseURL
        } else if ModelRepository.shared.isBuiltIn(providerID) {
            baseURL = ModelRepository.shared.defaultBaseURL(for: providerID)
        } else {
            baseURL = ModelRepository.shared.defaultBaseURL(for: "openai")
        }

        // Build conversation with agentic system prompt
        let systemPrompt = """
        You are an autonomous, thoughtful macOS terminal agent. Execute user requests reliably and safely.
        You may also be given MCP tools in addition to terminal access. Use MCP tools when they are a better fit than shell commands.
        If you use terminal commands, follow the pre-flight/execute/verify workflow strictly.

        ## AGENTIC WORKFLOW (Follow this pattern):

        ### 1. PRE-FLIGHT CHECKS (Always do this first!)
        Before ANY action, verify prerequisites:
        - File operations: Check if file/folder exists first (`ls`, `test -e`, `[ -f file ]`)
        - Deletions: List contents before removing, confirm target exists
        - Modifications: Read current state before changing
        - Installations: Check if already installed (`which`, `--version`)

        ### 2. EXECUTE WITH CONTEXT
        When calling execute_terminal_command, ALWAYS include a `purpose` parameter explaining:
        - "checking" - Verifying something exists/state
        - "executing" - Performing the main action
        - "verifying" - Confirming the result
        Example purposes: "Checking if image1.png exists", "Creating the backup directory", "Verifying file was deleted"

        ### 3. POST-ACTION VERIFICATION
        After modifying anything, verify it worked:
        - Created file? `ls` to confirm it exists
        - Deleted file? `ls` to confirm it's gone
        - Modified content? `cat` or `head` to verify changes
        - Installed app? Check version/existence

        ### 4. HANDLE FAILURES GRACEFULLY
        - If something doesn't exist: Tell the user clearly
        - If command fails: Analyze error, try alternative approach
        - If permission denied: Explain and suggest solutions
        - Never assume success without verification

        ## INTENT NORMALIZATION (CRITICAL FOR USER-FACING CONTENT):
        Before executing any action, rewrite the user's request into a clean action payload.
        Separate:
        - Instruction wrapper (what to do, who to send to, where to create)
        - User-facing payload (the actual message/body/title/content)

        Never include instruction phrasing in sent/saved content.
        For "send/tell/message/email X saying ...", only the text after "saying/that/with message" is the message body.

        Examples:
        - User: "Send a message to Alex saying we can grab dinner"
          -> recipient: Alex
          -> message body: "we can grab dinner"
          -> DO NOT send: "Send a message to Alex saying we can grab dinner"

        - User: "Create a reminder to call mom tomorrow"
          -> reminder title: "call mom"
          -> due date: tomorrow

        - User: "Write a note titled Grocery List with eggs, milk, bread"
          -> note title: "Grocery List"
          -> note body: "eggs, milk, bread"

        If payload extraction is ambiguous, choose the most literal minimal user-intended content.

        ## RESPONSE FORMAT:
        - Keep reasoning brief and clear
        - State what you're checking/doing before each command
        - After verification, give a clear success/failure summary
        - Use natural language, not code comments

        ## SAFETY RULES:
        - For destructive ops (rm, mv, overwrite): ALWAYS check target exists first
        - Show what will be affected before destroying
        - Prefer `rm -i` or listing contents before bulk deletes
        - Use full absolute paths when possible

        ## EXAMPLES OF GOOD BEHAVIOR:

        User: "Delete image1.png in Downloads"
        You: First check if it exists
        → execute_terminal_command(command: "ls -la ~/Downloads/image1.png", purpose: "Checking if image1.png exists")
        If exists → execute_terminal_command(command: "rm ~/Downloads/image1.png", purpose: "Deleting the file")
        Then verify → execute_terminal_command(command: "ls ~/Downloads/image1.png 2>&1", purpose: "Verifying file was deleted")
        Finally: "✓ Successfully deleted image1.png from Downloads."

        User: "Create a project folder with a readme"
        You: → Check if folder exists, create it, create readme, verify both

        ## NATIVE macOS APP CONTROL (Use osascript if there are no MCPs configured):
        For Reminders, Notes, Calendar, Messages, Mail, and other native macOS apps, use `osascript`:

        ### Reminders:
        - Create reminder (default list): `osascript -e 'tell application "Reminders" to make new reminder with properties {name:"<text>"}'`
        - Create in specific list: `osascript -e 'tell application "Reminders" to make new reminder at end of list "<ListName>" with properties {name:"<text>"}'`
        - With due date: `osascript -e 'tell application "Reminders" to make new reminder with properties {name:"<text>", due date:date "12/25/2024 3:00 PM"}'`
        - ⚠️ Do NOT use `reminders list 1` syntax - it causes errors. Use `list "<name>"` or omit the list entirely.

        ### Notes:
        - Create note: `osascript -e 'tell application "Notes" to make new note at folder "Notes" with properties {name:"<title>", body:"<content>"}'`

        ### Calendar:
        - Create event: `osascript -e 'tell application "Calendar" to tell calendar "<CalendarName>" to make new event with properties {summary:"<title>", start date:date "<date>", end date:date "<date>"}'`

        ### Messages:
        - Send iMessage: `osascript -e 'tell application "Messages" to send "<message>" to buddy "<phone/email>"'`

        ### General Pattern:
        Always use `osascript -e 'tell application "<AppName>" to ...'` for native app automation.

        The user is on macOS with zsh shell. Be thorough but efficient.
        When task is complete, provide a clear summary starting with ✓ or ✗.
        """

        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
        ]

        // Add conversation history
        var lastToolCallId: String? = nil

        for msg in self.conversationHistory {
            switch msg.role {
            case .user:
                messages.append(["role": "user", "content": msg.content])
            case .assistant:
                if let tc = msg.toolCall {
                    lastToolCallId = tc.id
                    messages.append([
                        "role": "assistant",
                        "content": msg.content,
                        "tool_calls": [
                            [
                                "id": tc.id,
                                "type": "function",
                                "function": [
                                    "name": tc.toolName,
                                    "arguments": tc.argumentsJSON.isEmpty ? "{}" : tc.argumentsJSON,
                                ],
                            ],
                        ],
                    ])
                } else {
                    messages.append(["role": "assistant", "content": msg.content])
                }
            case .tool:
                messages.append([
                    "role": "tool",
                    "content": msg.content,
                    "tool_call_id": msg.sourceToolCallID ?? lastToolCallId ?? "call_unknown",
                ])
            }
        }

        // Check streaming setting
        let enableStreaming = SettingsStore.shared.enableAIStreaming

        // Reasoning models (o1, o3, gpt-5) don't support temperature parameter at all
        let isReasoningModel = settings.isReasoningModel(model)
        let isTemperatureUnsupported = settings.isTemperatureUnsupported(model)

        // Get reasoning config for this model (e.g., reasoning_effort, enable_thinking)
        let reasoningConfig = SettingsStore.shared.getReasoningConfig(
            forModel: model, provider: providerID
        )
        var extraParams: [String: Any] = [:]
        if let rConfig = reasoningConfig, rConfig.isEnabled {
            if rConfig.parameterName == "enable_thinking" {
                extraParams = [rConfig.parameterName: rConfig.parameterValue == "true"]
            } else {
                extraParams = [rConfig.parameterName: rConfig.parameterValue]
            }
            DebugLogger.shared.debug(
                "Added reasoning param: \(rConfig.parameterName)=\(rConfig.parameterValue)",
                source: "CommandModeService"
            )
        }

        // Reset streaming state
        self.streamingText = ""
        self.streamingThinkingText = ""
        self.streamingBuffer = []
        self.thinkingBuffer = []
        self.lastUIUpdate = CFAbsoluteTimeGetCurrent()
        self.lastThinkingUIUpdate = CFAbsoluteTimeGetCurrent()
        self.lastNotchStreamingUIUpdate = CFAbsoluteTimeGetCurrent()

        // MCP bootstrap runs in the background. If it's not ready quickly, proceed with terminal-only tools.
        self.startMCPSessionBootstrapIfNeeded()
        let mcpReadyForThisTurn = await self.waitForMCPBootstrapIfNeeded(
            timeoutNanoseconds: self.mcpBootstrapWaitTimeoutNs)
        if !mcpReadyForThisTurn, self.cachedMCPTools.isEmpty {
            DebugLogger.shared.info(
                "MCP bootstrap still in progress; continuing this turn with terminal-only tools",
                source: "CommandModeService"
            )
        }
        let allTools = [TerminalService.toolDefinition] + self.cachedMCPTools

        // Build LLMClient configuration
        var config = LLMClient.Config(
            messages: messages,
            providerID: providerID,
            model: model,
            baseURL: baseURL,
            apiKey: apiKey,
            streaming: enableStreaming,
            tools: allTools,
            temperature: (isReasoningModel || isTemperatureUnsupported) ? nil : 0.1,
            maxTokens: isReasoningModel ? 32_000 : nil, // Reasoning models like o1 need a large budget for extended thought chains
            extraParameters: extraParams
        )

        // Keep retry logic (exponential backoff)
        config.maxRetries = 3
        config.retryDelayMs = 200

        // Add real-time streaming callbacks for UI updates (60fps throttled)
        if enableStreaming {
            // Thinking tokens callback
            config.onThinkingChunk = { [weak self] (chunk: String) in
                guard let self = self else { return }
                Task { @MainActor in
                    self.thinkingBuffer.append(chunk)

                    // 60fps UI update throttle for thinking
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - self.lastThinkingUIUpdate >= 0.016 {
                        self.lastThinkingUIUpdate = now
                        self.streamingThinkingText = self.thinkingBuffer.joined()
                    }
                }
            }

            // Content callback
            config.onContentChunk = { [weak self] (chunk: String) in
                guard let self = self else { return }
                Task { @MainActor in
                    self.streamingBuffer.append(chunk)

                    // 60fps UI update throttle
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - self.lastUIUpdate >= 0.016 {
                        self.lastUIUpdate = now
                        let fullContent = self.streamingBuffer.joined()
                        self.streamingText = fullContent

                        // Push to notch for real-time display
                        if self.shouldSyncCommandNotchState,
                           now - self.lastNotchStreamingUIUpdate
                           >= self.notchStreamingUpdateInterval
                        {
                            self.lastNotchStreamingUIUpdate = now
                            NotchContentState.shared.updateCommandStreamingText(fullContent)
                        }
                    }
                }
            }
        }

        DebugLogger.shared.info(
            "Using LLMClient for Command Mode (streaming=\(enableStreaming), messages=\(messages.count), history=\(self.conversationHistory.count), tools=\(allTools.count), mcpTools=\(self.cachedMCPTools.count), mcpReady=\(mcpReadyForThisTurn))",
            source: "CommandModeService"
        )

        let response = try await LLMClient.shared.call(config)

        // Final UI update - ensure all content is displayed
        let fullContent = self.streamingBuffer.joined()
        if !fullContent.isEmpty {
            self.streamingText = fullContent
            if self.shouldSyncCommandNotchState {
                NotchContentState.shared.updateCommandStreamingText(fullContent)
            }
        }

        // Small delay to let the final content render, then clear
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Capture final thinking before clearing (for message storage)
        let finalThinking =
            response.thinking ?? (self.thinkingBuffer.isEmpty ? nil : self.thinkingBuffer.joined())

        self.streamingText = "" // Clear streaming text when done
        self.streamingThinkingText = "" // Clear thinking text when done
        self.streamingBuffer = [] // Clear buffer
        self.thinkingBuffer = [] // Clear thinking buffer

        // Clear notch streaming text as well
        if self.shouldSyncCommandNotchState {
            NotchContentState.shared.updateCommandStreamingText("")
        }

        // Log thinking if present (for debugging)
        if let thinking = finalThinking {
            DebugLogger.shared.debug(
                "LLM thinking tokens extracted (\(thinking.count) chars)",
                source: "CommandModeService"
            )
        }

        // Convert LLMClient.Response to our internal LLMResponse
        let mappedToolCalls = response.toolCalls.map { toolCall in
            LLMResponse.ToolCallData(
                id: toolCall.id,
                name: toolCall.name,
                arguments: toolCall.arguments
            )
        }

        return LLMResponse(
            content: response.content,
            thinking: finalThinking, // Display-only
            toolCalls: mappedToolCalls
        )
    }
}
