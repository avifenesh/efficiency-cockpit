import Foundation

/// MCP Server for Efficiency Cockpit
/// Provides JSON-RPC interface over stdio for Claude Code integration

// MARK: - JSON-RPC Types

struct JSONRPCRequest: Codable {
    let jsonrpc: String
    let id: Int?
    let method: String
    let params: [String: AnyCodable]?
}

struct JSONRPCResponse: Codable {
    let jsonrpc: String = "2.0"
    let id: Int?
    let result: AnyCodable?
    let error: JSONRPCError?
}

struct JSONRPCError: Codable {
    let code: Int
    let message: String
    let data: AnyCodable?
}

// MARK: - MCP Types

struct MCPCapabilities: Codable {
    let resources: ResourcesCapability?
    let tools: ToolsCapability?
}

struct ResourcesCapability: Codable {
    let subscribe: Bool?
    let listChanged: Bool?
}

struct ToolsCapability: Codable {
    let listChanged: Bool?
}

struct MCPResource: Codable {
    let uri: String
    let name: String
    let description: String?
    let mimeType: String?
}

struct MCPTool: Codable {
    let name: String
    let description: String?
    let inputSchema: [String: AnyCodable]
}

// MARK: - AnyCodable Helper

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            self.value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Cannot encode value"))
        }
    }
}

// MARK: - MCP Server

class MCPServer {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let dataAccess = DataAccess()

    private let resources: [MCPResource] = [
        MCPResource(uri: "activity://current", name: "Current Activity", description: "The user's current activity", mimeType: "application/json"),
        MCPResource(uri: "activity://today", name: "Today's Activities", description: "All activities from today", mimeType: "application/json"),
        MCPResource(uri: "stats://daily", name: "Daily Statistics", description: "Aggregated daily statistics", mimeType: "application/json"),
        MCPResource(uri: "projects://list", name: "Projects", description: "Detected projects", mimeType: "application/json"),
        MCPResource(uri: "insights://recent", name: "Recent Insights", description: "Recent AI-generated insights", mimeType: "application/json")
    ]

    private let tools: [MCPTool] = [
        MCPTool(
            name: "get_current_activity",
            description: "Get the user's current activity (app, window, file)",
            inputSchema: ["type": AnyCodable("object"), "properties": AnyCodable([String: Any]())]
        ),
        MCPTool(
            name: "get_today_activities",
            description: "Get all activities from today",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "limit": ["type": "integer", "description": "Maximum number of activities to return"],
                    "app_filter": ["type": "string", "description": "Filter by app name"]
                ])
            ]
        ),
        MCPTool(
            name: "get_time_on_project",
            description: "Get time spent on a specific project",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "project": ["type": "string", "description": "Project name or path"]
                ]),
                "required": AnyCodable(["project"])
            ]
        ),
        MCPTool(
            name: "search_activities",
            description: "Search activities by keyword, app, or project",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "query": ["type": "string", "description": "Search query"],
                    "from_date": ["type": "string", "description": "Start date (ISO 8601)"],
                    "to_date": ["type": "string", "description": "End date (ISO 8601)"]
                ])
            ]
        ),
        MCPTool(
            name: "get_productivity_score",
            description: "Calculate productivity score for a time period",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "period": ["type": "string", "enum": ["today", "week", "month"], "description": "Time period"]
                ])
            ]
        ),
        MCPTool(
            name: "store_insight",
            description: "Store an AI-generated insight about the user's productivity",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "title": ["type": "string", "description": "Insight title"],
                    "content": ["type": "string", "description": "Insight content"],
                    "type": ["type": "string", "enum": ["tip", "warning", "achievement", "pattern"], "description": "Insight type"]
                ]),
                "required": AnyCodable(["title", "content", "type"])
            ]
        )
    ]

    func run() {
        while let line = readLine() {
            guard !line.isEmpty else { continue }

            do {
                let request = try decoder.decode(JSONRPCRequest.self, from: Data(line.utf8))
                let response = handleRequest(request)
                let responseData = try encoder.encode(response)
                if let responseString = String(data: responseData, encoding: .utf8) {
                    print(responseString)
                    fflush(stdout)
                }
            } catch {
                let errorResponse = JSONRPCResponse(
                    id: nil,
                    result: nil,
                    error: JSONRPCError(code: -32700, message: "Parse error: \(error.localizedDescription)", data: nil)
                )
                if let data = try? encoder.encode(errorResponse),
                   let str = String(data: data, encoding: .utf8) {
                    print(str)
                    fflush(stdout)
                }
            }
        }
    }

    private func handleRequest(_ request: JSONRPCRequest) -> JSONRPCResponse {
        switch request.method {
        case "initialize":
            return handleInitialize(request)
        case "resources/list":
            return handleListResources(request)
        case "resources/read":
            return handleReadResource(request)
        case "tools/list":
            return handleListTools(request)
        case "tools/call":
            return handleCallTool(request)
        default:
            return JSONRPCResponse(
                id: request.id,
                result: nil,
                error: JSONRPCError(code: -32601, message: "Method not found: \(request.method)", data: nil)
            )
        }
    }

    private func handleInitialize(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let result: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "resources": ["subscribe": false, "listChanged": false],
                "tools": ["listChanged": false]
            ],
            "serverInfo": [
                "name": "EfficiencyCockpit",
                "version": "1.0.0"
            ]
        ]
        return JSONRPCResponse(id: request.id, result: AnyCodable(result), error: nil)
    }

    private func handleListResources(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let resourceDicts = resources.map { resource -> [String: Any] in
            var dict: [String: Any] = [
                "uri": resource.uri,
                "name": resource.name
            ]
            if let desc = resource.description {
                dict["description"] = desc
            }
            if let mime = resource.mimeType {
                dict["mimeType"] = mime
            }
            return dict
        }
        return JSONRPCResponse(id: request.id, result: AnyCodable(["resources": resourceDicts]), error: nil)
    }

    private func handleReadResource(_ request: JSONRPCRequest) -> JSONRPCResponse {
        guard let params = request.params,
              let uri = params["uri"]?.value as? String else {
            return JSONRPCResponse(
                id: request.id,
                result: nil,
                error: JSONRPCError(code: -32602, message: "Invalid params: missing uri", data: nil)
            )
        }

        // Read from shared SwiftData database
        let content: [String: Any]
        switch uri {
        case "activity://current":
            content = dataAccess.getCurrentActivity() ?? ["error": "No current activity"]
        case "activity://today":
            let activities = dataAccess.getTodayActivities()
            content = ["activities": activities, "count": activities.count]
        case "stats://daily":
            content = dataAccess.getDailyStats()
        case "projects://list":
            content = ["projects": dataAccess.getProjects()]
        case "insights://recent":
            content = ["insights": dataAccess.getRecentInsights()]
        default:
            return JSONRPCResponse(
                id: request.id,
                result: nil,
                error: JSONRPCError(code: -32602, message: "Unknown resource: \(uri)", data: nil)
            )
        }

        let result: [String: Any] = [
            "contents": [
                [
                    "uri": uri,
                    "mimeType": "application/json",
                    "text": try? String(data: JSONSerialization.data(withJSONObject: content), encoding: .utf8) ?? "{}"
                ]
            ]
        ]
        return JSONRPCResponse(id: request.id, result: AnyCodable(result), error: nil)
    }

    private func handleListTools(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let toolDicts = tools.map { tool -> [String: Any] in
            var dict: [String: Any] = [
                "name": tool.name,
                "inputSchema": tool.inputSchema.mapValues { $0.value }
            ]
            if let desc = tool.description {
                dict["description"] = desc
            }
            return dict
        }
        return JSONRPCResponse(id: request.id, result: AnyCodable(["tools": toolDicts]), error: nil)
    }

    private func handleCallTool(_ request: JSONRPCRequest) -> JSONRPCResponse {
        guard let params = request.params,
              let name = params["name"]?.value as? String else {
            return JSONRPCResponse(
                id: request.id,
                result: nil,
                error: JSONRPCError(code: -32602, message: "Invalid params: missing tool name", data: nil)
            )
        }

        let arguments = params["arguments"]?.value as? [String: Any] ?? [:]

        // Execute tool with actual data
        let content: [String: Any]
        switch name {
        case "get_current_activity":
            content = dataAccess.getCurrentActivity() ?? ["error": "No current activity"]

        case "get_today_activities":
            let limit = arguments["limit"] as? Int ?? 100
            let appFilter = arguments["app_filter"] as? String
            let activities = dataAccess.getTodayActivities(limit: limit, appFilter: appFilter)
            content = ["activities": activities, "count": activities.count]

        case "get_time_on_project":
            let project = arguments["project"] as? String ?? ""
            content = dataAccess.getTimeOnProject(project)

        case "search_activities":
            let query = arguments["query"] as? String ?? ""
            var fromDate: Date?
            var toDate: Date?

            if let fromStr = arguments["from_date"] as? String {
                fromDate = ISO8601DateFormatter().date(from: fromStr)
            }
            if let toStr = arguments["to_date"] as? String {
                toDate = ISO8601DateFormatter().date(from: toStr)
            }

            let results = dataAccess.searchActivities(query: query, fromDate: fromDate, toDate: toDate)
            content = ["results": results, "count": results.count]

        case "get_productivity_score":
            let period = arguments["period"] as? String ?? "today"
            content = dataAccess.getProductivityScore(period: period)

        case "store_insight":
            let title = arguments["title"] as? String ?? ""
            let insightContent = arguments["content"] as? String ?? ""
            let type = arguments["type"] as? String ?? "tip"

            if let id = dataAccess.storeInsight(title: title, content: insightContent, type: type) {
                content = ["stored": true, "id": id]
            } else {
                content = ["stored": false, "error": "Failed to store insight"]
            }

        default:
            return JSONRPCResponse(
                id: request.id,
                result: nil,
                error: JSONRPCError(code: -32602, message: "Unknown tool: \(name)", data: nil)
            )
        }

        let result: [String: Any] = [
            "content": [
                [
                    "type": "text",
                    "text": (try? String(data: JSONSerialization.data(withJSONObject: content), encoding: .utf8)) ?? "{}"
                ]
            ]
        ]
        return JSONRPCResponse(id: request.id, result: AnyCodable(result), error: nil)
    }
}

// MARK: - Main

let server = MCPServer()
server.run()
