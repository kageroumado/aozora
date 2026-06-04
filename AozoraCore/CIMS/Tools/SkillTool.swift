import Foundation

/// Tool for discovering, viewing, creating, improving, and deleting markdown-based skills.
///
/// Skills are reusable instruction sets stored as `SKILL.md` files in named directories
/// within the configured skill search paths. Each skill has YAML frontmatter with metadata
/// (name, description, tags, version, when) and a markdown body with the actual instructions.
///
/// Actions:
/// - `list` — enumerate all available skills with their descriptions and tags.
/// - `view` — load and return the full `SKILL.md` content for a named skill.
/// - `create` — create a new skill directory with the provided content.
/// - `improve` — update an existing skill's content with improvements.
/// - `delete` — move a skill's directory to the Trash.
public nonisolated struct SkillTool: ToolExecutable {
    /// The manager used to discover and manipulate skills on disk.
    let manager: SkillManager

    public let name = "skill"

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "skill",
            description: """
            Manage markdown-based skills — reusable instruction sets stored as SKILL.md files.
            Actions:
            - "list" — show all available skills with descriptions and tags.
            - "view" — load the full content of a named skill.
            - "create" — create a new skill (requires name and content).
            - "improve" — update an existing skill with new content (requires name and content).
            - "delete" — move a skill to the Trash (requires name).
            """,
            parameters: [
                ToolParameter(
                    name: "action",
                    type: .enum(["list", "view", "create", "improve", "delete"]),
                    description: "Action to perform",
                ),
                ToolParameter(
                    name: "name",
                    type: .string,
                    description: "Skill name — required for view, create, improve, and delete",
                    optional: true,
                ),
                ToolParameter(
                    name: "content",
                    type: .string,
                    description: "Full SKILL.md content including YAML frontmatter — required for create and improve",
                    optional: true,
                ),
            ],
        )
    }

    /// Creates a skill tool backed by the given manager.
    ///
    /// - Parameter manager: The ``SkillManager`` to delegate discovery and I/O to.
    public init(manager: SkillManager) {
        self.manager = manager
    }

    public func execute(parameters: sending [String: Any], workingDirectory _: String) async throws -> ToolResult {
        let action = try requireString("action", from: parameters)

        switch action {
        case "list":
            return listSkills()
        case "view":
            let skillName = try requireString("name", from: parameters)
            return viewSkill(name: skillName)
        case "create":
            let skillName = try requireString("name", from: parameters)
            let content = try requireString("content", from: parameters)
            return createSkill(name: skillName, content: content)
        case "improve":
            guard let skillName = parameters["name"] as? String else {
                throw ToolError.invalidParameters("'name' is required for improve")
            }
            guard let content = parameters["content"] as? String else {
                throw ToolError.invalidParameters("'content' is required for improve")
            }
            return improveSkill(name: skillName, newContent: content)
        case "delete":
            let skillName = try requireString("name", from: parameters)
            return deleteSkill(name: skillName)
        default:
            return .failure("Unknown action '\(action)'. Use list, view, create, improve, or delete.")
        }
    }

    // MARK: - Actions

    /// List all available skills, formatted as a table.
    private func listSkills() -> ToolResult {
        let skills = manager.listSkills()

        if skills.isEmpty {
            return .success("No skills found in search paths.")
        }

        var lines = ["Available skills (\(skills.count)):"]
        for skill in skills {
            var line = "  \(skill.name)"
            if let version = skill.version {
                line += " v\(version)"
            }
            if !skill.description.isEmpty {
                line += " — \(skill.description)"
            }
            if !skill.tags.isEmpty {
                line += " [\(skill.tags.joined(separator: ", "))]"
            }
            lines.append(line)
        }

        return .success(lines.joined(separator: "\n"))
    }

    /// View the full content of a named skill.
    private func viewSkill(name: String) -> ToolResult {
        guard let content = manager.viewSkill(name: name) else {
            return .failure("Skill '\(name)' not found.")
        }
        return .success(content)
    }

    /// Create a new skill with the given name and content.
    private func createSkill(name: String, content: String) -> ToolResult {
        do {
            try manager.createSkill(name: name, content: content)
            return .success("Created skill '\(name)'.")
        } catch {
            return .failure("Failed to create skill '\(name)': \(error)")
        }
    }

    /// Update an existing skill's content with improvements.
    private func improveSkill(name: String, newContent: String) -> ToolResult {
        do {
            try manager.improveSkill(name: name, newContent: newContent)
            return ToolResult(content: "Improved skill '\(name)'.", isError: false)
        } catch {
            return ToolResult(content: "Failed to improve skill '\(name)': \(error)", isError: true)
        }
    }

    /// Delete a skill by moving it to the Trash.
    private func deleteSkill(name: String) -> ToolResult {
        do {
            try manager.deleteSkill(name: name)
            return .success("Deleted skill '\(name)'.")
        } catch {
            return .failure("Failed to delete skill '\(name)': \(error)")
        }
    }
}
