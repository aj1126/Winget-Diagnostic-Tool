# Markdown Formatting Rules

## Headings Spacing (MD022)

- All headings (styles `#` through `######`) must be surrounded by blank lines (at least one blank line above and at least one blank line below).
- Exception: The first heading at the very beginning of a file does not require a blank line above it, and a heading at the very end of a file does not require a blank line below it.

## Multiple Consecutive Blank Lines (MD012)

- Avoid multiple consecutive blank lines in the document.
- Maximum consecutive blank lines allowed is 1 (except inside code blocks).

## No Trailing Spaces (MD009)

- Avoid trailing spaces at the end of lines.
- Exception: Exactly two trailing spaces are permitted when used to insert a hard line break (`<br>`).

## Inline HTML (MD033)

- Avoid using raw HTML tags within Markdown documents (e.g., `<h1>`, `<div>`, etc.).
- Use "pure" Markdown equivalents instead (e.g., heading syntax `#`, formatting `**`, etc.).
- Exception: Specific HTML elements (like `<br>`) may be used inside Markdown tables if necessary for cell formatting.
