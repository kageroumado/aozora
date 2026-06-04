import Foundation
import Testing
@testable import Aozora

struct SkillManagerTests {
    @Test
    func `discovers skills in directory`() throws {
        let dir = NSTemporaryDirectory() + "skills-test-\(UUID().uuidString)"
        let skillDir = dir + "/my-skill"
        try FileManager.default.createDirectory(atPath: skillDir, withIntermediateDirectories: true)
        try """
        ---
        name: my-skill
        description: A test skill
        tags: [test]
        ---
        # My Skill
        Do the thing.
        """.write(toFile: skillDir + "/SKILL.md", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let manager = SkillManager(searchPaths: [dir])
        let skills = manager.listSkills()
        #expect(skills.count == 1)
        #expect(skills[0].name == "my-skill")
        #expect(skills[0].description == "A test skill")
    }

    @Test
    func `parses frontmatter correctly`() {
        let content = """
        ---
        name: test
        description: Test skill
        version: 2.0.0
        tags: [a, b]
        ---
        Body content here.
        """
        let (meta, body) = SkillManager.parseFrontmatter(content)
        #expect(meta["name"] as? String == "test")
        #expect(meta["version"] as? String == "2.0.0")
        #expect(body.contains("Body content here"))
    }

    @Test
    func `loads full skill content`() throws {
        let dir = NSTemporaryDirectory() + "skills-test-\(UUID().uuidString)"
        let skillDir = dir + "/loader-skill"
        try FileManager.default.createDirectory(atPath: skillDir, withIntermediateDirectories: true)
        try """
        ---
        name: loader-skill
        description: Tests loading
        ---
        Full content here with **markdown**.
        """.write(toFile: skillDir + "/SKILL.md", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let manager = SkillManager(searchPaths: [dir])
        let content = manager.viewSkill(name: "loader-skill")
        #expect(content != nil)
        #expect(try #require(content?.contains("Full content here")))
    }

    @Test
    func `returns nil for nonexistent skill`() {
        let manager = SkillManager(searchPaths: ["/nonexistent"])
        #expect(manager.viewSkill(name: "nope") == nil)
    }
}
