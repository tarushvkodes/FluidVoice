import Foundation

actor MCPSettingsStore {
    static let shared = MCPSettingsStore()

    struct SettingsDocument: Decodable, Equatable, Sendable {
        var version: Int
        var servers: [Server]

        private enum CodingKeys: String, CodingKey {
            case version
            case servers
            case mcpServers
        }

        init(version: Int = 1, servers: [Server] = []) {
            self.version = version
            self.servers = servers
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1

            if container.contains(.mcpServers) {
                let mcpServers =
                    try container.decodeIfPresent([String: Server].self, forKey: .mcpServers) ?? [:]
                self.servers = mcpServers.keys.sorted().compactMap { mcpServers[$0] }
            } else {
                self.servers = try container.decodeIfPresent([Server].self, forKey: .servers) ?? []
            }
        }
    }

    struct Server: Decodable, Equatable, Sendable {
        enum Transport: String, Codable, Sendable {
            case stdio
            case http
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case enabled
            case disabled
            case transport
            case type
            case command
            case args
            case env
            case cwd
            case url
            case headers
            case timeoutSeconds
        }

        var id: String
        var name: String?
        var enabled: Bool
        var transport: Transport

        // stdio
        var command: String?
        var args: [String]
        var env: [String: String]
        var cwd: String?

        // http
        var url: String?
        var headers: [String: String]

        var timeoutSeconds: TimeInterval

        init(
            id: String,
            name: String? = nil,
            enabled: Bool = true,
            transport: Transport,
            command: String? = nil,
            args: [String] = [],
            env: [String: String] = [:],
            cwd: String? = nil,
            url: String? = nil,
            headers: [String: String] = [:],
            timeoutSeconds: TimeInterval = 30
        ) {
            self.id = id
            self.name = name
            self.enabled = enabled
            self.transport = transport
            self.command = command
            self.args = args
            self.env = env
            self.cwd = cwd
            self.url = url
            self.headers = headers
            self.timeoutSeconds = timeoutSeconds
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            let explicitID = try container.decodeIfPresent(String.self, forKey: .id)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            let pathID: String? = {
                guard let last = decoder.codingPath.last, last.intValue == nil else { return nil }
                let key = last.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                return key.isEmpty ? nil : key
            }()

            self.id = pathID ?? explicitID ?? ""
            self.name = try container.decodeIfPresent(String.self, forKey: .name)

            let disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
            self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? !disabled

            if let transport = try container.decodeIfPresent(Transport.self, forKey: .transport) {
                self.transport = transport
            } else if let type = try container.decodeIfPresent(String.self, forKey: .type) {
                let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                switch normalizedType {
                case "stdio", "":
                    self.transport = .stdio
                case "http", "streamable-http":
                    self.transport = .http
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .type,
                        in: container,
                        debugDescription:
                        "Unsupported MCP server type '\(type)'. Supported values are 'stdio' and 'http'."
                    )
                }
            } else if try container.decodeIfPresent(String.self, forKey: .url) != nil {
                self.transport = .http
            } else {
                self.transport = .stdio
            }

            self.command = try container.decodeIfPresent(String.self, forKey: .command)
            self.args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
            self.env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
            self.cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
            self.url = try container.decodeIfPresent(String.self, forKey: .url)
            self.headers =
                try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
            self.timeoutSeconds =
                try container.decodeIfPresent(TimeInterval.self, forKey: .timeoutSeconds) ?? 30
        }
    }

    struct LoadedSettings: Sendable {
        let document: SettingsDocument
        let fileURL: URL
        let modifiedAt: Date
    }

    enum StoreError: LocalizedError {
        case applicationSupportUnavailable
        case invalidJSON(String)
        case invalidConfiguration(String)

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                return "Could not access Application Support directory for MCP settings."
            case let .invalidJSON(details):
                return "Invalid MCP settings.json: \(details)"
            case let .invalidConfiguration(details):
                return "Invalid MCP settings configuration: \(details)"
            }
        }
    }

    private let fileName = "settings.json"
    private let appSupportFolder = "FluidVoice"
    private let bundledTemplateName = "mcp.settings.default"
    private var cachedSettings: LoadedSettings?

    private init() {}

    func settingsFileURL() throws -> URL {
        guard
            let baseDirectory = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else {
            throw StoreError.applicationSupportUnavailable
        }
        let directory = baseDirectory.appendingPathComponent(
            self.appSupportFolder, isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(self.fileName, isDirectory: false)
    }

    @discardableResult
    func ensureSettingsFileExists() throws -> URL {
        let fileURL = try self.settingsFileURL()
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return fileURL }

        if let bundledURL = Bundle.main.url(
            forResource: self.bundledTemplateName, withExtension: "json"
        ),
            let data = try? Data(contentsOf: bundledURL)
        {
            try data.write(to: fileURL, options: .atomic)
        } else {
            let template = Self.defaultTemplateJSON()
            try template.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        return fileURL
    }

    func loadRawJSON() throws -> String {
        let fileURL = try self.ensureSettingsFileExists()
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    func validateJSON(_ json: String) throws -> SettingsDocument {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()

        let decoded: SettingsDocument
        do {
            decoded = try decoder.decode(SettingsDocument.self, from: data)
        } catch {
            throw StoreError.invalidJSON(error.localizedDescription)
        }

        return try self.validateAndNormalize(decoded)
    }

    func saveRawJSON(_ json: String) throws {
        _ = try self.validateJSON(json)
        let fileURL = try self.ensureSettingsFileExists()
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
        self.cachedSettings = nil
    }

    func loadSettings(forceReload: Bool = false) throws -> LoadedSettings {
        let fileURL = try self.ensureSettingsFileExists()
        let modifiedAt = self.modifiedDate(for: fileURL)

        if !forceReload,
           let cachedSettings,
           cachedSettings.fileURL == fileURL,
           cachedSettings.modifiedAt == modifiedAt
        {
            return cachedSettings
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()

        let decoded: SettingsDocument
        do {
            decoded = try decoder.decode(SettingsDocument.self, from: data)
        } catch {
            throw StoreError.invalidJSON(error.localizedDescription)
        }

        let validated = try self.validateAndNormalize(decoded)
        let loaded = LoadedSettings(document: validated, fileURL: fileURL, modifiedAt: modifiedAt)
        self.cachedSettings = loaded
        return loaded
    }

    private func validateAndNormalize(_ document: SettingsDocument) throws -> SettingsDocument {
        guard document.version == 1 else {
            throw StoreError.invalidConfiguration(
                "Unsupported settings version \(document.version). Expected version 1.")
        }

        var normalizedServers: [Server] = []
        var seenIDs = Set<String>()

        for var server in document.servers {
            let id = server.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                throw StoreError.invalidConfiguration(
                    "Server id must not be empty. Use a non-empty key under 'mcpServers'.")
            }
            let normalizedID = id.lowercased()
            guard !seenIDs.contains(normalizedID) else {
                throw StoreError.invalidConfiguration("Duplicate server id '\(id)'")
            }
            seenIDs.insert(normalizedID)
            server.id = id

            if let name = server.name?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty
            {
                server.name = name
            } else {
                server.name = nil
            }

            server.timeoutSeconds = min(max(server.timeoutSeconds, 5), 300)

            switch server.transport {
            case .stdio:
                let command = server.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !command.isEmpty else {
                    throw StoreError.invalidConfiguration(
                        "Server '\(id)' (stdio) requires 'command'.")
                }
                server.command = command
                server.args = server.args
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if let cwd = server.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !cwd.isEmpty
                {
                    server.cwd = cwd
                } else {
                    server.cwd = nil
                }
                server.url = nil

            case .http:
                let urlString = server.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let url = URL(string: urlString),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https"
                else {
                    throw StoreError.invalidConfiguration(
                        "Server '\(id)' (http) requires a valid http(s) 'url'.")
                }
                server.url = urlString
                server.command = nil
                server.args = []
                server.cwd = nil
            }

            server.env = Dictionary(
                uniqueKeysWithValues: server.env.compactMap { key, value in
                    let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedKey.isEmpty else { return nil }
                    return (trimmedKey, value)
                })

            server.headers = Dictionary(
                uniqueKeysWithValues: server.headers.compactMap { key, value in
                    let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedKey.isEmpty else { return nil }
                    return (trimmedKey, value)
                })

            normalizedServers.append(server)
        }

        return SettingsDocument(version: 1, servers: normalizedServers)
    }

    private func modifiedDate(for fileURL: URL) -> Date {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let modified = attrs[.modificationDate] as? Date
        {
            return modified
        }
        return .distantPast
    }

    private static func defaultTemplateJSON() -> String {
        """
        {
          "mcpServers": {
            "altic-mcp": {
              "enabled": false,
              "command": "uv",
              "args": [
                "run",
                "--project",
                "/FULL/PATH/TO/altic-mcp",
                "/FULL/PATH/TO/altic-mcp/server.py"
              ],
              "env": {}
            }
          }
        }
        """
    }
}
