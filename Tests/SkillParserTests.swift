import Testing
import Foundation
@testable import AgentSkillManager

@Suite("SkillParser Tests")
struct SkillParserTests {

    // MARK: - Valid Parsing

    @Test("Parses valid frontmatter with name and description")
    func parseValidFrontmatter() throws {
        let content = """
        ---
        name: my-skill
        description: A useful skill for testing
        ---
        # Instructions
        Do something useful.
        """

        let result = try SkillParser.parse(content: content)

        #expect(result.name == "my-skill")
        #expect(result.description == "A useful skill for testing")
    }

    @Test("Parses frontmatter with multi-line description using folded scalar")
    func parseMultiLineDescriptionFolded() throws {
        let content = """
        ---
        name: multi-line-skill
        description: >
          A skill that does
          multiple things across
          several lines
        ---
        Body content here.
        """

        let result = try SkillParser.parse(content: content)

        #expect(result.name == "multi-line-skill")
        #expect(result.description.contains("A skill that does"))
        #expect(result.description.contains("multiple things"))
    }

    @Test("Parses frontmatter with multi-line description using literal block scalar")
    func parseMultiLineDescriptionLiteral() throws {
        let content = """
        ---
        name: literal-skill
        description: |
          Line one
          Line two
          Line three
        ---
        Body content here.
        """

        let result = try SkillParser.parse(content: content)

        #expect(result.name == "literal-skill")
        #expect(result.description.contains("Line one"))
        #expect(result.description.contains("Line two"))
    }

    @Test("Extracts body content after closing frontmatter delimiter")
    func parseBodyContent() throws {
        let content = """
        ---
        name: body-test
        description: Testing body extraction
        ---
        # Skill Instructions

        You are a specialized agent that does things.

        ## Details

        More details here.
        """

        let result = try SkillParser.parse(content: content)

        #expect(result.body.contains("# Skill Instructions"))
        #expect(result.body.contains("You are a specialized agent"))
        #expect(result.body.contains("More details here."))
    }

    @Test("Parses frontmatter with extra unknown fields and still extracts name and description")
    func parseWithExtraFields() throws {
        let content = """
        ---
        name: extra-fields-skill
        description: A skill with extra metadata
        version: 2.0
        author: Test Author
        tags: [testing, example]
        ---
        Body here.
        """

        let result = try SkillParser.parse(content: content)

        #expect(result.name == "extra-fields-skill")
        #expect(result.description == "A skill with extra metadata")
    }

    @Test("Parses quoted scalar values without retaining quotes")
    func parseQuotedScalarValues() throws {
        let content = """
        ---
        name: "quoted-skill"
        description: "A quoted description"
        ---
        Body here.
        """

        let result = try SkillParser.parse(content: content)

        #expect(result.name == "quoted-skill")
        #expect(result.description == "A quoted description")
    }

    @Test("Body is empty string when no content follows frontmatter")
    func parseEmptyBody() throws {
        let content = """
        ---
        name: no-body
        description: Skill with no body
        ---
        """

        let result = try SkillParser.parse(content: content)

        #expect(result.name == "no-body")
        #expect(result.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Error Handling

    @Test("Throws when name field is missing")
    func parseMissingName() throws {
        let content = """
        ---
        description: A skill without a name
        ---
        Body content.
        """

        #expect(throws: (any Error).self) {
            try SkillParser.parse(content: content)
        }
    }

    @Test("Throws when description field is missing")
    func parseMissingDescription() throws {
        let content = """
        ---
        name: no-description-skill
        ---
        Body content.
        """

        #expect(throws: (any Error).self) {
            try SkillParser.parse(content: content)
        }
    }

    @Test("Throws when file has no frontmatter delimiters")
    func parseNoFrontmatterDelimiters() throws {
        let content = """
        # Just a regular markdown file
        No frontmatter here at all.
        """

        #expect(throws: (any Error).self) {
            try SkillParser.parse(content: content)
        }
    }

    @Test("Throws when file content is empty")
    func parseEmptyContent() throws {
        let content = ""

        #expect(throws: (any Error).self) {
            try SkillParser.parse(content: content)
        }
    }

    @Test("Throws when only opening delimiter is present")
    func parseSingleDelimiter() throws {
        let content = """
        ---
        name: broken
        description: Missing closing delimiter
        """

        #expect(throws: (any Error).self) {
            try SkillParser.parse(content: content)
        }
    }
}
