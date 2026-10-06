import Foundation
import Testing
@testable import NoteMDCore

@Suite struct FrontMatterTests {
    @Test func noFrontMatter() {
        let text = MarkdownText("# Hello\n\nBody")
        #expect(text.frontMatter == nil)
        #expect(text.body == "# Hello\n\nBody")
        #expect(text.text == "# Hello\n\nBody")
    }

    @Test func roundTripsVerbatim() {
        let source = "---\ntitle: Convert sprite\n# keep me\ntags: []\nvendors: [claude, codex]\n---\n# Prompt\n"
        let text = MarkdownText(source)
        #expect(text.text == source)
        #expect(text.frontMatter?.title == "Convert sprite")
        #expect(text.frontMatter?.keys == ["title", "tags", "vendors"])
    }

    @Test func settingTagsPreservesUnknownKeys() {
        var text = MarkdownText("---\ntitle: X\ntags: []\nvendors: [claude, codex]   # inline comment\n---\nBody\n")
        text.frontMatter?.setTags(["work", "#AI prompts", "work", "a,b"])
        #expect(text.text == "---\ntitle: X\ntags: [work, AI prompts, \"a,b\"]\nvendors: [claude, codex]   # inline comment\n---\nBody\n")
        #expect(text.frontMatter?.tags == ["work", "AI prompts", "a,b"])
    }

    @Test func addingAndRemovingKeys() {
        var text = MarkdownText("Body only")
        var frontMatter = FrontMatter()
        frontMatter.setTags(["one"])
        text.frontMatter = frontMatter
        #expect(text.text == "---\ntags: [one]\n---\nBody only")
        text.frontMatter?.setTags([])
        #expect(text.text == "Body only")
    }

    @Test func blockSequenceAndCRLF() {
        let text = MarkdownText("---\r\ntags:\r\n- a\r\n- b\r\n---\r\nBody")
        #expect(text.frontMatter?.tags == ["a", "b"])
    }

    @Test func invalidYAMLKeepsText() {
        let source = "---\ntitle: [unclosed\n---\nBody"
        let text = MarkdownText(source)
        #expect(text.frontMatter?.parseError != nil)
        #expect(text.text == source)
    }

    @Test func unclosedDelimiterIsBody() {
        let text = MarkdownText("---\nnot front matter")
        #expect(text.frontMatter == nil)
    }

    @Test func scalarQuoting() {
        #expect(YAMLScalar.block("plain words") == "plain words")
        #expect(YAMLScalar.block("yes") == "\"yes\"")
        #expect(YAMLScalar.block("12") == "\"12\"")
        #expect(YAMLScalar.block("a: b") == "\"a: b\"")
        #expect(YAMLScalar.block("line\nbreak") == "\"line\\nbreak\"")
        #expect(YAMLScalar.flow("x, y") == "\"x, y\"")
    }

    @Test func parametersRoundTrip() {
        var frontMatter = FrontMatter(yaml: "title: Prompt\nparams:\n- name: game_name\n  type: text\n")
        #expect(frontMatter.isTemplate)
        var parameters = frontMatter.parameters
        #expect(parameters.map(\.name) == ["game_name"])
        parameters.append(TemplateParameter(name: "style", label: "Art style", type: .choice, required: true, defaultValue: .text("pixel"), options: ["pixel", "paper, cut"]))
        parameters.append(TemplateParameter(name: "notes", type: .textarea, help: "Extra \"context\""))
        frontMatter.setParameters(parameters)
        let reparsed = FrontMatter(yaml: frontMatter.yaml)
        #expect(reparsed.parameters == parameters)
        #expect(reparsed.title == "Prompt")
        frontMatter.setParameters([])
        #expect(frontMatter.yaml == "title: Prompt\n")
        #expect(!frontMatter.isTemplate)
    }
}

@Suite struct TemplateParameterTests {
    @Test func aliasesParse() {
        let yaml = """
        params:
          - {name: a, type: string}
          - {name: b, type: multiline}
          - {name: c, type: int, default: 3}
          - {name: d, type: boolean, default: yes}
          - {name: e, type: select, options: [x, y]}
          - {name: f, type: multiselect, default: [x]}
          - {name: g, type: path}
          - {name: h, type: directory}
          - {name: i, type: date, default: 2026-01-02, format: dd/MM/yyyy}
          - {name: j, type: array, default: "one, two"}
          - k
        """
        let parameters = FrontMatter(yaml: yaml + "\n").parameters
        #expect(parameters.map(\.type) == [.text, .textarea, .number, .toggle, .choice, .multichoice, .file, .folder, .date, .list, .text])
        #expect(parameters[2].defaultValue == .number(3))
        #expect(parameters[3].defaultValue == .bool(true))
        #expect(parameters[4].options == ["x", "y"])
        #expect(parameters[5].defaultValue == .list(["x"]))
        #expect(parameters[8].format == "dd/MM/yyyy")
        #expect(parameters[9].defaultValue == .list(["one", "two"]))
        #expect(parameters[10].name == "k")
    }

    @Test func mappingForm() {
        let parameters = FrontMatter(yaml: "params:\n  topic: text\n  count: {type: number}\n").parameters
        #expect(parameters.map(\.name) == ["count", "topic"])
        #expect(parameters[0].type == .number)
    }

    @Test func humanize() {
        #expect(TemplateParameter.humanize("game_name") == "Game name")
        #expect(TemplateParameter(name: "x", label: "Custom").displayLabel == "Custom")
        #expect(TemplateParameter.isValidName("game_name"))
        #expect(!TemplateParameter.isValidName("1abc"))
        #expect(!TemplateParameter.isValidName("a b"))
    }
}
