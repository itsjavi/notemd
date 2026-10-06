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
