---
name: create-reusable-prompt
description: Write a NoteMD reusable prompt, a Markdown template note whose front matter defines form fields (`params`) and whose body uses `{{…}}` placeholders, conditions and loops. Use when asked to create, convert, review or fix a prompt template or a NoteMD template note.
---

# Create a reusable prompt

A reusable prompt is a NoteMD template: a Markdown note whose YAML front matter lists `params`. NoteMD turns the
parameters into a form (_Use Template_). The note body is the prompt, and the form values fill its placeholders. The
result can be copied or saved as a new note.

`schema.json`, next to this file, is the JSON Schema for template front matter. Its `$defs/note` covers the front
matter of regular notes too.

## Steps

1. Find the parts of the prompt that change between uses. Each one becomes a parameter. A few clearly labelled fields
   beat many optional ones.
2. Pick each field's type from the table below. Use `choice` for a fixed set of values, `toggle` for on/off
   instructions and `list` for any number of items.
3. Write the front matter and validate it (see Validation).
4. Write the body with the syntax below. Put the instructions that depend on a value inside a condition.
5. Check that every `{{name}}` has a parameter, every parameter is used, every block is closed, and every comparison
   uses a value that is one of the field's options.
6. Save it as `<Title>.md` in the vault, usually in a `Templates/` folder. Any folder works: NoteMD lists every note
   with `params` under _Templates_ in the sidebar.

## Example

```markdown
---
title: Bug triage
tags: [prompts]
params:
  - name: product
    required: true
    placeholder: NoteMD
  - name: severity
    type: choice
    options: [low, medium, high, critical]
    default: medium
  - name: platforms
    type: multichoice
    options: [macOS, iOS, web]
  - name: report
    type: textarea
    label: Bug report
    required: true
  - name: max_questions
    type: number
    label: Follow-up questions
    default: 3
  - name: logs
    type: list
    help: One log file path per line
---

# Triage a {{severity}} bug in {{product}}

Read this bug report and decide what to do next:

{{report}}

{{#if severity == critical}}
Treat it as an incident and start with the immediate mitigation.
{{#elseif severity == high}}
Propose a fix for the next release.
{{else}}
Suggest where it fits in the backlog.
{{/if}}
{{#if platforms == iOS}}
Check whether the iOS app shares the affected code.
{{/if}}
{{#if max_questions > 0}}
Ask at most {{max_questions}} follow-up questions.
{{/if}}
{{#if logs}}
Logs to read:
{{#each logs}}
- `{{.}}`
{{/each}}
{{/if}}
```

## Front matter

The file must start with a `---` line. The front matter ends at the next `---` line.

| Key      | Value                                                                     |
| -------- | ------------------------------------------------------------------------- |
| `title`  | Display title. Defaults to the first `# heading`, then the file name      |
| `tags`   | List of tags, without `#`                                                 |
| `params` | List of parameters, in form order. This is what makes the note a template |
| other    | Kept as written and shown in the preview's front matter table             |

Each parameter has a `name` and optionally `type`, `label`, `required`, `help`, `placeholder`, `options`, `format` and
`default`:

| `type`        | Form control                 | Value in the body                      | `default`                     |
| ------------- | ---------------------------- | -------------------------------------- | ----------------------------- |
| `text`        | One-line field (the default) | The text                               | string                        |
| `textarea`    | Multi-line field             | The text                               | string                        |
| `number`      | Number field                 | The number (`3`, not `3.0`)            | number                        |
| `toggle`      | Switch                       | `true` or `false`; use it in `{{#if}}` | boolean                       |
| `choice`      | Pop-up menu of `options`     | The picked option                      | one of the options (or first) |
| `multichoice` | Checkboxes of `options`      | Picked options, joined with `, `       | list of options               |
| `file`        | Path field with a picker     | Absolute path                          | string                        |
| `folder`      | Path field with a picker     | Absolute path                          | string                        |
| `date`        | Date picker                  | Formatted with `format` (`yyyy-MM-dd`) | `today` or `YYYY-MM-DD`       |
| `list`        | One item per line            | Items joined with `, `                 | list of strings               |

Names use letters, digits, `_`, `-` or `.`, and start with a letter or `_`. `label` defaults to the humanized name
(`max_questions` becomes "Max questions"). `required` fields must be filled before the form gives a result.

## Template syntax

| Syntax                                              | Effect                                                                 |
| --------------------------------------------------- | ---------------------------------------------------------------------- |
| `{{name}}`                                          | Inserts the value                                                      |
| `{{@today}}`, `{{@now}}`                            | Today's date (`yyyy-MM-dd`), the date and time (`yyyy-MM-dd HH:mm`)    |
| `{{#if name}}…{{else}}…{{/if}}`                     | Shows the first part when the value is set, the `{{else}}` part if not |
| `{{#unless name}}…{{/unless}}`                      | The opposite of `#if`                                                  |
| `{{#if name == value}}`, `{{#if name != value}}`    | Compares the value with a literal                                      |
| `{{#if name > 5}}` (also `<`, `<=`, `>=`)           | Compares numbers                                                       |
| `{{#if a}}…{{#elseif b}}…{{else}}…{{/if}}`          | Chains conditions; the first match wins. `{{else if b}}` also works    |
| `{{#each name}}{{@index}}. {{.}}{{else}}…{{/each}}` | Repeats for each list item; `{{else}}` shows when the list is empty    |

Rules:

- **Set** means text that isn't blank, a toggle that is on, a list with items, or any number or date.
- **A `choice` is always set**, because it starts on its first option. Compare it instead: `{{#if severity == high}}`.
- **Literals** need quotes only when they contain spaces: `{{#if status == "in review"}}`. Single quotes work too.
- **`==` and `!=`** compare text exactly, including case. Numbers compare by value (`3 == 3.0`). For a `multichoice`
  or `list`, `==` checks whether the item is picked and `!=` whether it isn't. Toggles compare with `true` or `false`.
- **`<`, `<=`, `>`, `>=`** need numbers on both sides: a `number` field, or a choice whose options are numbers. Anything
  else is false.
- **Inside `#each`**, `.` is the current item and `@index` its position from 1. Both work in conditions:
  `{{#if . == urgent}}`, `{{#if @index > 1}}`.
- **There is no `&&`, `||` or parentheses.** Nest blocks instead.
- **A block tag alone on its line** removes that line, so blocks leave no blank lines.
- **Unknown placeholders stay as written.** A misspelled `{{nmae}}` shows up in the result, and a condition on an
  unknown name is false.

## Validation

Validate the front matter against `schema.json`, for example with ajv:

```bash
awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{exit} f' "Templates/Bug triage.md" > /tmp/front-matter.yml
npx -y ajv-cli@5 validate --spec=draft2020 --all-errors -s skills/create-reusable-prompt/schema.json -d /tmp/front-matter.yml
```

The schema accepts only the names NoteMD writes. NoteMD also reads some aliases (`parameters`, `description`,
`choices`, type names like `select` or `bool`), but use the canonical names in new templates.
