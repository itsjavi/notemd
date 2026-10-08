import Foundation
import Testing
@testable import NoteMDCore

@Suite struct TemplateRendererTests {
    @Test func variables() {
        let renderer = TemplateRenderer(values: ["game_name": .text("Zelda"), "count": .number(3), "items": .list(["a", "b"])])
        #expect(renderer.render("Give **{{game_name}}** {{ count }} {{items}} {{unknown}}") == "Give **Zelda** 3 a, b {{unknown}}")
    }

    @Test func ifElseUnless() {
        let renderer = TemplateRenderer(values: ["on": .bool(true), "off": .bool(false), "empty": .text("")])
        #expect(renderer.render("{{#if on}}yes{{else}}no{{/if}}") == "yes")
        #expect(renderer.render("{{#if off}}yes{{else}}no{{/if}}") == "no")
        #expect(renderer.render("{{#if empty}}yes{{/if}}") == "")
        #expect(renderer.render("{{#unless off}}shown{{/unless}}") == "shown")
        #expect(renderer.render("{{#if missing}}x{{else}}fallback{{/if}}") == "fallback")
    }

    @Test func comparisons() {
        let renderer = TemplateRenderer(values: [
            "status": .text("in review"), "max": .number(12), "level": .text("3"),
            "platforms": .list(["iOS", "macOS"]), "flag": .bool(true), "empty": .text(""),
        ])
        #expect(renderer.render(#"{{#if status == "in review"}}R{{/if}}{{#if status == 'in review'}}r{{/if}}"#) == "Rr")
        #expect(renderer.render("{{#if status == done}}D{{else}}not done{{/if}}") == "not done")
        #expect(renderer.render(#"{{#if status != "done"}}open{{/if}}{{#unless status == "done"}}!{{/unless}}"#) == "open!")
        #expect(renderer.render("{{#if max >= 10}}big{{/if}}{{#if max>=13}}huge{{/if}}") == "big")
        #expect(renderer.render("{{#if max == 12.0}}a{{/if}}{{#if max < 12}}b{{/if}}{{#if max <= 12}}c{{/if}}{{#if max > 11.5}}d{{/if}}") == "acd")
        #expect(renderer.render("{{#if level > 2}}deep{{/if}}{{#if status > 2}}x{{else}}not a number{{/if}}") == "deepnot a number")
        #expect(renderer.render(#"{{#if platforms == "iOS"}}i{{/if}}{{#if platforms != "watchOS"}}w{{/if}}"#) == "iw")
        #expect(renderer.render(#"{{#if flag == true}}on{{/if}}{{#if empty == ""}}blank{{/if}}"#) == "onblank")
        #expect(renderer.render(#"{{#if missing != "x"}}m{{/if}}{{#if missing == "x"}}n{{/if}}"#) == "m")
    }

    @Test func comparisonsInsideEach() {
        let renderer = TemplateRenderer(values: ["tags": .list(["bug", "ui", "urgent"])])
        let template = #"{{#each tags}}{{#if . == "urgent"}}!{{.}}{{else}}{{.}}{{/if}}{{#if @index < 3}},{{/if}}{{/each}}"#
        #expect(renderer.render(template) == "bug,ui,!urgent")
    }

    @Test func elseIfChains() {
        let template = #"{{#if size == "S"}}small{{#elseif size == "M"}}medium{{else if size == "L"}}large{{else}}other{{/if}}"#
        for (size, expected) in [("S", "small"), ("M", "medium"), ("L", "large"), ("XL", "other")] {
            #expect(TemplateRenderer(values: ["size": .text(size)]).render(template) == expected)
        }
        #expect(TemplateRenderer(values: ["n": .number(5)]).render("{{#unless n > 3}}low{{#elseif n > 4}}high{{/unless}}") == "high")
        #expect(TemplateRenderer(values: [:]).render("{{#if a}}A{{#elseif b}}B{{/if}}") == "")
    }

    @Test func standaloneElseIfLinesAreRemoved() {
        let template = """
        {{#if n >= 10}}
        many
        {{#elseif n >= 1}}
        some
        {{else}}
        none
        {{/if}}
        end
        """
        #expect(TemplateRenderer(values: ["n": .number(3)]).render(template) == "some\nend")
    }

    @Test func malformedConditions() {
        let renderer = TemplateRenderer(values: ["a": .bool(true)])
        #expect(renderer.render("{{#if a ==}}x{{else}}y{{/if}}") == "y")
        #expect(renderer.render("{{#elseif a}}stray") == "{{#elseif a}}stray")
        #expect(renderer.render("{{#if a}}x{{else}}y{{#elseif a}}z{{/if}}") == "x")
        #expect(renderer.render("{{#each a}}x{{#elseif a}}y{{/each}}") == "x{{#elseif a}}y")
        #expect(renderer.render("{{#if a}}x{{#elseif b}}y") == "{{#if a}}x{{#elseif b}}y")
    }

    @Test func each() {
        let renderer = TemplateRenderer(values: ["files": .list(["a.swift", "b.swift"])])
        #expect(renderer.render("{{#each files}}{{@index}}. {{.}}\n{{/each}}") == "1. a.swift\n2. b.swift\n")
        #expect(renderer.render("{{#each nothing}}x{{else}}none{{/each}}") == "none")
    }

    @Test func standaloneBlockLinesAreRemoved() {
        let template = """
        Intro
        {{#if a}}
        A line
        {{else}}
        Not A
        {{/if}}
          {{#each list}}
        - {{.}}
          {{/each}}
        End
        """
        let renderer = TemplateRenderer(values: ["a": .bool(true), "list": .list(["x", "y"])])
        #expect(renderer.render(template) == "Intro\nA line\n- x\n- y\nEnd")
    }

    @Test func nestedBlocks() {
        let renderer = TemplateRenderer(values: ["a": .bool(true), "b": .bool(false), "list": .list(["1", "2"])])
        #expect(renderer.render("{{#if a}}[{{#if b}}B{{else}}{{#each list}}{{.}}{{/each}}{{/if}}]{{/if}}") == "[12]")
    }

    @Test func unbalancedTagsStayLiteral() {
        let renderer = TemplateRenderer(values: ["a": .bool(true)])
        #expect(renderer.render("{{#if a}}open") == "{{#if a}}open")
        #expect(renderer.render("close{{/if}}") == "close{{/if}}")
        #expect(renderer.render("{{#weird x}}") == "{{#weird x}}")
    }

    @Test func datesUseFormat() {
        let date = ISO8601DateFormatter.dateOnly.date(from: "2026-03-04")!
        let parameters = [TemplateParameter(name: "due", type: .date, format: "dd/MM/yyyy")]
        let renderer = TemplateRenderer(parameters: parameters, values: ["due": .date(date), "plain": .date(date)], now: date)
        #expect(renderer.render("{{due}} {{plain}} {{@today}}") == "04/03/2026 2026-03-04 2026-03-04")
    }

    @Test func referencedNames() {
        #expect(TemplateRenderer.referencedNames(in: "{{a}} {{#if b}}{{c}}{{/if}} {{.}} {{@today}}") == ["a", "b", "c"])
        let conditions = #"{{#if status == "x"}}{{#elseif max > 1}}{{/if}}{{#each tags}}{{#if . == "a"}}{{/if}}{{/each}}"#
        #expect(TemplateRenderer.referencedNames(in: conditions) == ["status", "max", "tags"])
    }

    @Test func requiredValidation() {
        let parameters = [
            TemplateParameter(name: "name", required: true),
            TemplateParameter(name: "flag", type: .toggle, required: true),
            TemplateParameter(name: "optional"),
        ]
        #expect(TemplateValidation.missingRequired(parameters, values: ["name": .text("  "), "flag": .bool(false)]) == ["name"])
        #expect(TemplateValidation.missingRequired(parameters, values: ["name": .text("x"), "flag": .bool(false)]).isEmpty)
    }
}
