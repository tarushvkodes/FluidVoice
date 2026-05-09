import Foundation
import MCP

#if canImport(System)
import System
#else
import SystemPackage
#endif

@MainActor
final class MCPManager {
    static let shared = MCPManager()
    private static let maxToolNameLength = 64

    struct StatusSummary: Sendable {
        let enabledServers: Int
        let connectedServers: Int
        let lastError: String?
    }

    struct ToolExecutionContent: Codable, Hashable, Sendable {
        let type: String
        let text: String?
        let data: String?
        let mimeType: String?
        let uri: String?
        let metadata: [String: String]
    }

    struct ToolExecutionResult: Sendable {
        let success: Bool
        let toolName: String
        let serverID: String?
        let output: String
        let error: String?
        let isError: Bool
        let content: [ToolExecutionContent]
    }

    private struct ToolRoute {
        let serverID: String
        let originalToolName: String
    }

    private final class ServerRuntime {
        let config: MCPSettingsStore.Server
        let client: Client
        let process: Process?
        let stdInPipe: Pipe?
        let stdOutPipe: Pipe?
        let stdErrPipe: Pipe?
        var tools: [Tool]

        init(
            config: MCPSettingsStore.Server,
            client: Client,
            process: Process? = nil,
            stdInPipe: Pipe? = nil,
            stdOutPipe: Pipe? = nil,
            stdErrPipe: Pipe? = nil,
            tools: [Tool]
        ) {
            self.config = config
            self.client = client
            self.process = process
            self.stdInPipe = stdInPipe
            self.stdOutPipe = stdOutPipe
            self.stdErrPipe = stdErrPipe
            self.tools = tools
        }
    }

    enum MCPManagerError: LocalizedError {
        case invalidURL(String)
        case missingCommand(String)
        case unknownTool(String)
        case unavailableServer(String)
        case invalidArguments(String)
        case timeout(TimeInterval)

        var errorDescription: String? {
            switch self {
            case let .invalidURL(url):
                return "Invalid MCP server URL: \(url)"
            case let .missingCommand(serverID):
                return "MCP server '\(serverID)' requires a command"
            case let .unknownTool(name):
                return "Unknown MCP tool '\(name)'"
            case let .unavailableServer(serverID):
                return "MCP server '\(serverID)' is unavailable"
            case let .invalidArguments(details):
                return "Invalid MCP tool arguments: \(details)"
            case let .timeout(seconds):
                return "MCP operation timed out after \(Int(seconds))s"
            }
        }
    }

    private let settingsStore = MCPSettingsStore.shared

    private var lastModifiedAt: Date?
    private var settingsFileURLCache: URL?
    private var enabledServerIDs: Set<String> = []
    private var connectionErrors: [String: String] = [:]
    private var runtimes: [String: ServerRuntime] = [:]
    private var cachedToolDefinitions: [[String: Any]] = []
    private var toolRoutes: [String: ToolRoute] = [:]
    private var lastError: String?

    private init() {}

    func reloadConfiguration(force: Bool = false) async {
        do {
            let loaded = try await self.settingsStore.loadSettings(forceReload: force)
            self.settingsFileURLCache = loaded.fileURL

            if !force,
               let lastModifiedAt = self.lastModifiedAt,
               lastModifiedAt == loaded.modifiedAt
            {
                return
            }

            self.lastModifiedAt = loaded.modifiedAt
            await self.applyConfiguration(loaded.document, forceReconnect: force)

        } catch {
            self.lastError = error.localizedDescription
            self.enabledServerIDs = []
            self.connectionErrors = [:]
            self.cachedToolDefinitions = []
            self.toolRoutes = [:]
            await self.disconnectAllServers()
            DebugLogger.shared.error(
                "MCPManager: Failed loading settings.json: \(error.localizedDescription)",
                source: "MCPManager"
            )
        }
    }

    func toolDefinitions(reloadIfNeeded: Bool = true) async -> [[String: Any]] {
        if reloadIfNeeded {
            await self.reloadConfiguration(force: false)
        }
        return self.cachedToolDefinitions
    }

    func settingsFileURL() async -> URL? {
        if let url = self.settingsFileURLCache {
            return url
        }
        if let ensuredURL = try? await self.settingsStore.ensureSettingsFileExists() {
            self.settingsFileURLCache = ensuredURL
            return ensuredURL
        }
        return nil
    }

    func loadSettingsJSON() async throws -> String {
        try await self.settingsStore.loadRawJSON()
    }

    func validateSettingsJSON(_ json: String) async throws {
        _ = try await self.settingsStore.validateJSON(json)
    }

    func saveSettingsJSON(_ json: String) async throws {
        try await self.settingsStore.saveRawJSON(json)
        self.lastModifiedAt = nil
    }

    func statusSummary(reloadIfNeeded: Bool = true) async -> StatusSummary {
        if reloadIfNeeded {
            await self.reloadConfiguration(force: false)
        }
        return self.currentStatusSummary()
    }

    func callTool(functionName: String, arguments: [String: Any], reloadIfNeeded: Bool = true) async
        -> ToolExecutionResult
    {
        if reloadIfNeeded {
            await self.reloadConfiguration(force: false)
        }

        guard let route = self.toolRoutes[functionName] else {
            return ToolExecutionResult(
                success: false,
                toolName: functionName,
                serverID: nil,
                output: "",
                error: MCPManagerError.unknownTool(functionName).localizedDescription,
                isError: true,
                content: []
            )
        }

        guard let runtime = self.runtimes[route.serverID] else {
            return ToolExecutionResult(
                success: false,
                toolName: functionName,
                serverID: route.serverID,
                output: "",
                error: MCPManagerError.unavailableServer(route.serverID).localizedDescription,
                isError: true,
                content: []
            )
        }

        do {
            let mcpArguments = try Self.convertArguments(arguments)
            let timeout = max(runtime.config.timeoutSeconds, 5)
            let (content, isError) = try await self.withTimeout(seconds: timeout) {
                try await runtime.client.callTool(
                    name: route.originalToolName,
                    arguments: mcpArguments.isEmpty ? nil : mcpArguments
                )
            }

            let convertedContent = content.map(Self.convertToolContent)
            let output = Self.flattenedOutput(from: convertedContent)
            let toolErrored = isError ?? false
            let success = !toolErrored
            let fallbackError = toolErrored ? "MCP tool returned an error response." : nil

            return ToolExecutionResult(
                success: success,
                toolName: functionName,
                serverID: route.serverID,
                output: output,
                error: fallbackError,
                isError: toolErrored,
                content: convertedContent
            )

        } catch {
            return ToolExecutionResult(
                success: false,
                toolName: functionName,
                serverID: route.serverID,
                output: "",
                error: error.localizedDescription,
                isError: true,
                content: []
            )
        }
    }

    private func currentStatusSummary() -> StatusSummary {
        return StatusSummary(
            enabledServers: self.enabledServerIDs.count,
            connectedServers: self.runtimes.count,
            lastError: self.lastError
        )
    }

    private func applyConfiguration(
        _ document: MCPSettingsStore.SettingsDocument,
        forceReconnect: Bool
    ) async {
        self.lastError = nil
        self.connectionErrors = [:]

        let enabledServers = document.servers.filter { $0.enabled }
        self.enabledServerIDs = Set(enabledServers.map { $0.id })

        let incomingByID = Dictionary(uniqueKeysWithValues: enabledServers.map { ($0.id, $0) })

        // Disconnect removed or disabled servers.
        let staleIDs = Set(self.runtimes.keys).subtracting(self.enabledServerIDs)
        for staleID in staleIDs {
            await self.disconnectServer(id: staleID)
        }

        // Connect or refresh enabled servers.
        for server in enabledServers {
            if !forceReconnect, let runtime = self.runtimes[server.id], runtime.config == server {
                continue
            }

            await self.disconnectServer(id: server.id)
            do {
                let runtime = try await self.connectServer(server)
                self.runtimes[server.id] = runtime
            } catch {
                self.connectionErrors[server.id] = error.localizedDescription
                DebugLogger.shared.error(
                    "MCPManager: Failed connecting server '\(server.id)': \(error.localizedDescription)",
                    source: "MCPManager"
                )
            }
        }

        // Disconnect servers no longer in incoming config.
        let knownIDs = Set(incomingByID.keys)
        let removedIDs = Set(self.runtimes.keys).subtracting(knownIDs)
        for removedID in removedIDs {
            await self.disconnectServer(id: removedID)
        }

        self.rebuildToolCatalog()

        if !self.connectionErrors.isEmpty {
            let joined = self.connectionErrors
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: " | ")
            self.lastError = joined
        }
    }

    private func connectServer(_ server: MCPSettingsStore.Server) async throws -> ServerRuntime {
        switch server.transport {
        case .stdio:
            return try await self.connectStdioServer(server)
        case .http:
            return try await self.connectHTTPServer(server)
        }
    }

    private func connectHTTPServer(_ server: MCPSettingsStore.Server) async throws -> ServerRuntime {
        guard let urlString = server.url, let endpoint = URL(string: urlString) else {
            throw MCPManagerError.invalidURL(server.url ?? "")
        }

        let requestHeaders = server.headers
        let transport = HTTPClientTransport(
            endpoint: endpoint,
            streaming: false,
            requestModifier: { request in
                var request = request
                for (key, value) in requestHeaders {
                    request.setValue(value, forHTTPHeaderField: key)
                }
                return request
            }
        )

        let client = Client(name: "FluidVoice", version: Self.clientVersion)
        let timeout = max(server.timeoutSeconds, 5)

        _ = try await self.withTimeout(seconds: timeout) {
            try await client.connect(transport: transport)
        }

        let (tools, _) = try await self.withTimeout(seconds: timeout) {
            try await client.listTools()
        }

        DebugLogger.shared.info(
            "MCPManager: Connected HTTP MCP server '\(server.id)' with \(tools.count) tools",
            source: "MCPManager"
        )

        return ServerRuntime(
            config: server,
            client: client,
            tools: tools
        )
    }

    private func connectStdioServer(_ server: MCPSettingsStore.Server) async throws -> ServerRuntime {
        guard let command = server.command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty
        else {
            throw MCPManagerError.missingCommand(server.id)
        }

        let process = Process()
        let stdInPipe = Pipe()
        let stdOutPipe = Pipe()
        let stdErrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + server.args
        process.standardInput = stdInPipe
        process.standardOutput = stdOutPipe
        process.standardError = stdErrPipe

        if let cwd = server.cwd, !cwd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in server.env {
            environment[key] = value
        }
        process.environment = environment

        let serverID = server.id
        stdErrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines =
                text
                    .split(whereSeparator: { $0.isNewline })
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

            for line in lines {
                DebugLogger.shared.debug("MCP[\(serverID)] stderr: \(line)", source: "MCPManager")
            }
        }

        do {
            try process.run()
        } catch {
            stdErrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        let transport = StdioTransport(
            input: .init(rawValue: stdOutPipe.fileHandleForReading.fileDescriptor),
            output: .init(rawValue: stdInPipe.fileHandleForWriting.fileDescriptor)
        )

        let client = Client(name: "FluidVoice", version: Self.clientVersion)
        let timeout = max(server.timeoutSeconds, 5)

        do {
            _ = try await self.withTimeout(seconds: timeout) {
                try await client.connect(transport: transport)
            }

            let (tools, _) = try await self.withTimeout(seconds: timeout) {
                try await client.listTools()
            }

            DebugLogger.shared.info(
                "MCPManager: Connected stdio MCP server '\(server.id)' with \(tools.count) tools",
                source: "MCPManager"
            )

            return ServerRuntime(
                config: server,
                client: client,
                process: process,
                stdInPipe: stdInPipe,
                stdOutPipe: stdOutPipe,
                stdErrPipe: stdErrPipe,
                tools: tools
            )
        } catch {
            stdErrPipe.fileHandleForReading.readabilityHandler = nil
            await client.disconnect()
            if process.isRunning {
                process.terminate()
            }
            throw error
        }
    }

    private func disconnectServer(id: String) async {
        guard let runtime = self.runtimes.removeValue(forKey: id) else { return }

        await runtime.client.disconnect()

        runtime.stdErrPipe?.fileHandleForReading.readabilityHandler = nil
        runtime.stdErrPipe?.fileHandleForReading.closeFile()
        runtime.stdOutPipe?.fileHandleForReading.closeFile()
        runtime.stdInPipe?.fileHandleForWriting.closeFile()

        if let process = runtime.process, process.isRunning {
            process.terminate()
        }
    }

    private func disconnectAllServers() async {
        let ids = Array(self.runtimes.keys)
        for id in ids {
            await self.disconnectServer(id: id)
        }
    }

    private func rebuildToolCatalog() {
        self.cachedToolDefinitions = []
        self.toolRoutes = [:]

        var usedToolNames = Set<String>()

        for serverID in self.runtimes.keys.sorted() {
            guard let runtime = self.runtimes[serverID] else { continue }

            for tool in runtime.tools {
                let openAIName = self.uniqueToolName(
                    serverID: serverID,
                    toolName: tool.name,
                    usedToolNames: &usedToolNames
                )

                let definition = self.makeOpenAIToolDefinition(
                    openAIName: openAIName,
                    tool: tool,
                    serverID: serverID
                )

                self.cachedToolDefinitions.append(definition)
                self.toolRoutes[openAIName] = ToolRoute(
                    serverID: serverID, originalToolName: tool.name
                )
            }
        }
    }

    private func uniqueToolName(
        serverID: String, toolName: String, usedToolNames: inout Set<String>
    ) -> String {
        let base = Self.sanitizeToolName("mcp_\(serverID)_\(toolName)")
        let candidate = Self.makeUniqueSanitizedToolName(base: base, usedToolNames: &usedToolNames)

        return candidate
    }

    static func makeUniqueSanitizedToolName(base: String, usedToolNames: inout Set<String>) -> String {
        let truncatedBase = String(base.prefix(Self.maxToolNameLength))
        var candidate = truncatedBase
        var counter = 2

        while usedToolNames.contains(candidate) {
            let suffix = "_\(counter)"
            let reservedBaseLength = max(0, Self.maxToolNameLength - suffix.count)
            candidate = String(truncatedBase.prefix(reservedBaseLength)) + suffix
            counter += 1
        }

        usedToolNames.insert(candidate)
        return candidate
    }

    private static func sanitizeToolName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(value.unicodeScalars.count)

        for scalar in value.unicodeScalars {
            if allowed.contains(scalar) {
                scalars.append(scalar)
            } else {
                scalars.append("_")
            }
        }

        var sanitized = String(String.UnicodeScalarView(scalars))
        while sanitized.contains("__") {
            sanitized = sanitized.replacingOccurrences(of: "__", with: "_")
        }
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        if sanitized.isEmpty {
            sanitized = "mcp_tool"
        }

        if let first = sanitized.first, first.isNumber {
            sanitized = "mcp_\(sanitized)"
        }

        if sanitized.count > Self.maxToolNameLength {
            sanitized = String(sanitized.prefix(Self.maxToolNameLength))
        }

        return sanitized
    }

    private func makeOpenAIToolDefinition(openAIName: String, tool: Tool, serverID: String)
        -> [String: Any]
    {
        let schemaAny = Self.foundationValue(from: tool.inputSchema)
        var parameters = schemaAny as? [String: Any] ?? [:]
        if parameters["type"] == nil {
            parameters["type"] = "object"
        }
        if parameters["properties"] == nil {
            parameters["properties"] = [:]
        }

        let description = tool.description ?? "MCP tool '\(tool.name)' from server '\(serverID)'."

        return [
            "type": "function",
            "name": openAIName,
            "description": description,
            "parameters": parameters,
        ]
    }

    private static func convertToolContent(_ content: Tool.Content) -> ToolExecutionContent {
        switch content {
        case let .text(text, _, _):
            return ToolExecutionContent(
                type: "text", text: text, data: nil, mimeType: nil, uri: nil, metadata: [:]
            )
        case let .image(data, mimeType, _, _):
            return ToolExecutionContent(
                type: "image", text: nil, data: data, mimeType: mimeType, uri: nil, metadata: [:]
            )
        case let .audio(data, mimeType, _, _):
            return ToolExecutionContent(
                type: "audio", text: nil, data: data, mimeType: mimeType, uri: nil, metadata: [:]
            )
        case let .resource(resource, _, _):
            return ToolExecutionContent(
                type: "resource",
                text: resource.text,
                data: resource.blob,
                mimeType: resource.mimeType,
                uri: resource.uri,
                metadata: [:]
            )
        case let .resourceLink(uri, name, title, description, mimeType, _):
            let parts = [name, title, description].compactMap { $0 }.filter { !$0.isEmpty }
            let summary = parts.isEmpty ? nil : parts.joined(separator: " - ")
            return ToolExecutionContent(
                type: "resource_link",
                text: summary,
                data: nil,
                mimeType: mimeType,
                uri: uri,
                metadata: [:]
            )
        }
    }

    private static func flattenedOutput(from content: [ToolExecutionContent]) -> String {
        var chunks: [String] = []
        chunks.reserveCapacity(content.count)

        for item in content {
            switch item.type {
            case "text":
                if let text = item.text, !text.isEmpty {
                    chunks.append(text)
                }
            case "resource":
                if let text = item.text, !text.isEmpty {
                    chunks.append(text)
                } else if let uri = item.uri {
                    chunks.append("Resource: \(uri)")
                }
            case "image":
                chunks.append("Image content (\(item.mimeType ?? "unknown mime"))")
            case "audio":
                chunks.append("Audio content (\(item.mimeType ?? "unknown mime"))")
            default:
                break
            }
        }

        return chunks.joined(separator: "\n")
    }

    private static func foundationValue(from value: Value) -> Any {
        switch value {
        case .null:
            return NSNull()
        case let .bool(bool):
            return bool
        case let .int(int):
            return int
        case let .double(double):
            return double
        case let .string(string):
            return string
        case let .data(mimeType, data):
            var payload: [String: Any] = [
                "type": "data",
                "data": data.base64EncodedString(),
            ]
            if let mimeType {
                payload["mimeType"] = mimeType
            }
            return payload
        case let .array(array):
            return array.map(Self.foundationValue(from:))
        case let .object(object):
            var mapped: [String: Any] = [:]
            mapped.reserveCapacity(object.count)
            for (key, nestedValue) in object {
                mapped[key] = Self.foundationValue(from: nestedValue)
            }
            return mapped
        }
    }

    private static func convertArguments(_ arguments: [String: Any]) throws -> [String: Value] {
        var converted: [String: Value] = [:]
        converted.reserveCapacity(arguments.count)

        for (key, rawValue) in arguments {
            converted[key] = try self.mcpValue(from: rawValue)
        }

        return converted
    }

    private static func mcpValue(from rawValue: Any) throws -> Value {
        switch rawValue {
        case is NSNull:
            return .null

        case let value as Bool:
            return .bool(value)

        case let value as Int:
            return .int(value)

        case let value as Double:
            return .double(value)

        case let value as Float:
            return .double(Double(value))

        case let value as String:
            return .string(value)

        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let doubleValue = number.doubleValue
            if floor(doubleValue) == doubleValue {
                return .int(number.intValue)
            }
            return .double(doubleValue)

        case let array as [Any]:
            return try .array(array.map { try self.mcpValue(from: $0) })

        case let dictionary as [String: Any]:
            var converted: [String: Value] = [:]
            converted.reserveCapacity(dictionary.count)
            for (key, nestedValue) in dictionary {
                converted[key] = try self.mcpValue(from: nestedValue)
            }
            return .object(converted)

        default:
            throw MCPManagerError.invalidArguments(
                "Unsupported argument type: \(type(of: rawValue))")
        }
    }

    private func withTimeout<T>(
        seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeoutNanoseconds = UInt64(max(1, Int(seconds.rounded())) * 1_000_000_000)

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw MCPManagerError.timeout(seconds)
            }

            guard let first = try await group.next() else {
                throw MCPManagerError.timeout(seconds)
            }
            group.cancelAll()
            return first
        }
    }

    private static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
    }
}
