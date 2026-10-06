import Foundation

/// The HTML shell and GitHub-like stylesheet used by the preview.
enum PreviewPage {
    static func html(body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src notemd-file: https: http: data:; media-src notemd-file: https:; style-src 'unsafe-inline'; font-src notemd-file: data:;">
        <meta name="color-scheme" content="light dark">
        <style>\(css)</style>
        </head><body><article id="content" class="markdown-body">\(body)</article></body></html>
        """
    }

    static let css = """
    :root {
      --fg: #1f2328; --muted: #59636e; --border: #d1d9e0; --border-muted: #d1d9e0b3;
      --canvas-subtle: #f6f8fa; --code-bg: #818b981f; --link: #0969da; --mark: #fff8c5;
      --note: #0969da; --tip: #1a7f37; --important: #8250df; --warning: #9a6700; --caution: #d1242f;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --fg: #e6edf3; --muted: #9198a1; --border: #3d444d; --border-muted: #3d444db3;
        --canvas-subtle: #ffffff0a; --code-bg: #656c7633; --link: #4493f8; --mark: #bb800926;
        --note: #4493f8; --tip: #3fb950; --important: #ab7df8; --warning: #d29922; --caution: #f85149;
      }
    }
    html { background: transparent; }
    body { margin: 0; padding: 28px 32px 64px; font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: var(--fg); -webkit-font-smoothing: antialiased; }
    .markdown-body { max-width: 780px; margin: 0 auto; word-wrap: break-word; }
    .markdown-body > *:first-child { margin-top: 0 !important; }
    .markdown-body > *:last-child { margin-bottom: 0 !important; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    p, blockquote, ul, ol, dl, table, pre, details, .markdown-alert { margin: 0 0 16px; }
    h1, h2, h3, h4, h5, h6 { margin: 24px 0 16px; font-weight: 600; line-height: 1.25; }
    h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid var(--border-muted); }
    h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid var(--border-muted); }
    h3 { font-size: 1.25em; } h4 { font-size: 1em; } h5 { font-size: .875em; } h6 { font-size: .85em; color: var(--muted); }
    ul, ol { padding-left: 2em; }
    li + li { margin-top: .25em; }
    li > p { margin-top: 16px; }
    ul ul, ul ol, ol ol, ol ul { margin: 0; }
    li:has(> input[type=checkbox]) { list-style: none; }
    li > input[type=checkbox] { margin: 0 .3em .25em -1.5em; vertical-align: middle; accent-color: var(--link); }
    blockquote { padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
    hr { height: .25em; margin: 24px 0; padding: 0; background: var(--border); border: 0; }
    code, pre, kbd, samp { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 85%; }
    code { padding: .2em .4em; border-radius: 6px; background: var(--code-bg); white-space: break-spaces; }
    pre { padding: 16px; overflow: auto; line-height: 1.45; border-radius: 6px; background: var(--canvas-subtle); }
    pre code { padding: 0; background: transparent; font-size: 100%; white-space: pre; }
    kbd { padding: 3px 5px; border: 1px solid var(--border); border-bottom-width: 2px; border-radius: 6px; background: var(--canvas-subtle); }
    table { border-spacing: 0; border-collapse: collapse; display: block; width: max-content; max-width: 100%; overflow: auto; }
    th, td { padding: 6px 13px; border: 1px solid var(--border); }
    th { font-weight: 600; }
    tr:nth-child(2n) { background: var(--canvas-subtle); }
    img { max-width: 100%; box-sizing: content-box; }
    mark { background: var(--mark); color: inherit; }
    details summary { cursor: pointer; }
    del { color: var(--muted); }
    .footnotes { font-size: 12px; color: var(--muted); border-top: 1px solid var(--border); margin-top: 32px; padding-top: 8px; }
    .footnotes ol { padding-left: 16px; }
    sup a { font-size: .85em; }
    table.front-matter { font-size: 13px; margin-bottom: 24px; }
    table.front-matter td { color: var(--muted); }
    .markdown-alert { padding: 8px 16px; border-left: .25em solid var(--border); }
    .markdown-alert > :last-child { margin-bottom: 0; }
    .markdown-alert-title { display: flex; align-items: center; font-weight: 600; margin-bottom: 4px; }
    .markdown-alert-note { border-left-color: var(--note); } .markdown-alert-note .markdown-alert-title { color: var(--note); }
    .markdown-alert-tip { border-left-color: var(--tip); } .markdown-alert-tip .markdown-alert-title { color: var(--tip); }
    .markdown-alert-important { border-left-color: var(--important); } .markdown-alert-important .markdown-alert-title { color: var(--important); }
    .markdown-alert-warning { border-left-color: var(--warning); } .markdown-alert-warning .markdown-alert-title { color: var(--warning); }
    .markdown-alert-caution { border-left-color: var(--caution); } .markdown-alert-caution .markdown-alert-title { color: var(--caution); }
    """
}
