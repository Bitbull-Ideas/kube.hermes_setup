---
name: markdown-pdf
description: "Use when creating a polished PDF from Markdown. Render Markdown with a print-focused HTML/CSS theme, cover page, metadata, table of contents, syntax-highlighted code, images, headers/footers, page numbers, and verified pagination."
version: 2.0.1
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [markdown, pdf, documents, publishing, typography, weasyprint]
    related_skills: [nano-pdf, ocr-and-documents]
---

# Markdown PDF

Create attractive, print-ready PDFs from Markdown using a deterministic local pipeline:

```text
Markdown + optional YAML front matter
  → Python-Markdown extensions + Pygments highlighting
  → semantic HTML
  → pip-only fpdf2 backend (default), or optional WeasyPrint backend
  → PDF
```

The default theme is an editorial technical-document style: generous whitespace, readable typography, restrained indigo accents, polished code blocks, tables, callouts, a cover page, running header/footer, and page numbers. The fpdf2 backend is the reliable no-system-package path; the optional WeasyPrint backend gives richer CSS pagination when its native libraries are available. Override the CSS when using WeasyPrint; fpdf2 intentionally supports a smaller print-oriented HTML subset.

## When to Use

Use this skill when the user asks for:

- a beautiful, professional, printable PDF from `.md` content;
- a report, proposal, guide, README, technical design, or handbook as PDF;
- Markdown conversion with title page, TOC, page numbers, headers, footers, or code highlighting.

Do not use this as the first choice for slide decks, pixel-perfect brochures, heavily interactive HTML, or documents whose main content is scanned images. Use a presentation, design, or OCR workflow instead.

## Prerequisites

The renderer is the bundled `scripts/render_markdown_pdf.py`. It needs Python packages `markdown`, `pygments`, and `fpdf2`. Optionally, it uses WeasyPrint for richer CSS when native libraries are available; otherwise it uses the pip-only fpdf2 backend.

Check first:

```bash
python -c 'import markdown, pygments, fpdf; print("markdown-pdf ready")'
```

Install in the active environment (no OS packages required for the default backend):

```bash
python -m pip install markdown pygments fpdf2
```

Optional richer CSS backend:

```bash
python -m pip install weasyprint
```

The script prefers WeasyPrint only when explicitly enabled with `MARKDOWN_PDF_USE_WEASYPRINT=1`; otherwise it uses the pip-only fpdf2 backend. Playwright/Chromium is not required. The fpdf2 backend supports selectable text, cover pages, TOC, headings, lists, tables, code blocks, and local images; complex browser-only CSS is intentionally ignored. For Unicode source content, place `NotoSans-Regular.ttf` and `NotoSans-Bold.ttf` in `.markdown-pdf-fonts/` or set `MARKDOWN_PDF_FONT_DIR`; the renderer registers regular, bold, italic, and bold-italic faces. Mermaid/code-block arrows and other symbols are normalized only in the fpdf2 output path when the Courier code font cannot represent them. See `references/container-pip-only.md` for the tested container workflow. Do not claim a successful render until the command exits 0 and the output is verified.

## Quick Start

```bash
python /path/to/markdown-pdf/scripts/render_markdown_pdf.py report.md -o report.pdf
```

Useful options:

```bash
python .../render_markdown_pdf.py report.md \
  -o report.pdf \
  --title "Quarterly Engineering Report" \
  --author "Acme Engineering" \
  --subtitle "Q2 2026" \
  --theme indigo \
  --toc \
  --css brand.css
```

The script resolves relative images and links relative to the Markdown file. It writes an intermediate HTML file only when `--html` is supplied.

## Markdown Front Matter

A document may start with YAML front matter. It is removed from the rendered body and supplies document metadata:

```yaml
---
title: Platform Architecture
subtitle: Decision record and implementation guide
author: Jane Doe
organization: Acme Engineering
date: 2026-07-11
version: 1.0
keywords: architecture, platform, reliability
---
```

CLI options override front-matter values. `title` is also used for the PDF metadata and cover page. Set `--no-cover` for short documents or when the Markdown already has its own title page.

## Authoring Guidance

1. Start with one H1 title; use H2/H3 for the hierarchy. The renderer creates the TOC from H2–H4 headings.
2. Put a manual page break before a major section with `<div class="page-break"></div>` when needed.
3. Use fenced code blocks with a language identifier, for example `````python```; Pygments will highlight them.
4. Use blockquotes beginning with `> **Note:**`, `> **Tip:**`, or `> **Warning:**` for styled callouts.
5. Keep wide tables compact. Prefer short column labels and use landscape CSS only through a custom stylesheet.
6. Use local assets with relative paths. For remote assets, download them first when reproducibility matters.
7. Avoid raw JavaScript: WeasyPrint is a print renderer, not a browser runtime.

## Theme and Custom CSS

The default CSS lives beside the script as `templates/editorial.css`. The script accepts one or more `--css` files; later files win. Keep print-specific rules in the override:

```css
:root { --accent: #0f766e; }
.cover { background: #0f172a; }
@page { size: A4; margin: 22mm 18mm 20mm; }
```

Use `--theme` for `indigo`, `forest`, or `slate`. If the user wants a brand match, inspect available design guidance first and translate its colors/typography into print CSS rather than copying web-only interactions.

## Required Workflow

1. **Inspect inputs.** Identify the Markdown file, its asset directory, desired paper size, title/author, and whether a cover/TOC is wanted. Do not invent missing factual metadata; omit it or ask.
2. **Check renderer readiness.** Import `markdown`, `pygments`, and `fpdf`, and verify the input/output paths. If the Markdown contains non-ASCII characters, check for the configured NotoSans font files before rendering. If dependencies are missing, install them with pip in the active project environment.
3. **Render.** Run `scripts/render_markdown_pdf.py` with explicit `-o`. Use `--toc` for documents longer than roughly three pages and `--no-cover` for short notes.
4. **Inspect output.** Verify the PDF exists, is non-empty, has the expected page count, and contains selectable text. When visual verification is available, render or open the first page, one body page, and the final page; check clipping, blank pages, code overflow, table wrapping, footer collisions, and missing images.
5. **Iterate CSS, not content.** If layout is wrong, use a small `--css` override and rerender. Do not claim success until the final PDF was opened or parsed and the output path is known.

A completed render is evidenced by all of these:

- the command exits 0;
- the output file exists and has a plausible size;
- page count is reported or checked with an available PDF tool;
- text extraction finds the title and at least one body heading;
- the selected backend emits no rendering errors (WeasyPrint only when explicitly enabled);

## Verification Commands

```bash
# File and PDF header
stat -c '%n %s bytes' report.pdf
python -c "from pathlib import Path; p=Path('report.pdf'); assert p.read_bytes()[:5] == b'%PDF-'"

# If available, inspect pages/text
pdfinfo report.pdf | grep -E 'Pages|Page size'
pdftotext report.pdf - | head -40
```

If `pdfinfo`/`pdftotext` are unavailable, use Python with `pypdf` if already installed; do not fabricate page counts. A PDF can be visually attractive while still being unusable if text is rasterized, so check text extraction whenever possible.

## Common Pitfalls

1. **Missing fonts:** CSS fallback fonts vary by machine. Prefer widely available families (`DejaVu Sans`, `Liberation Sans`, `Noto Sans`) or ship licensed font files and reference them with `@font-face`.
2. **Remote images fail:** network access during rendering may be blocked. Download assets locally and reference them with relative paths.
3. **Code runs off the page:** use shorter lines or a custom rule such as `pre { white-space: pre-wrap; overflow-wrap: break-word; }`; do not reduce body text globally first.
4. **Headings orphaned from content:** add `h2, h3 { break-after: avoid; }` and insert a manual page break for intentional section starts.
5. **TOC mismatch:** the script generates the TOC from rendered headings. Avoid duplicate heading IDs and verify links after changing heading text.
6. **Web CSS does not print well:** flex-heavy layouts, sticky positioning, JavaScript, and viewport units are unreliable. Use normal flow, CSS page-break rules, and print units.
7. **Huge PDFs:** downscale oversized images before embedding and avoid embedding the same large image repeatedly.
8. **Backend mismatch:** fpdf2 does not implement arbitrary browser CSS. Treat the supplied HTML/CSS as a design source, but verify the actual PDF; use `MARKDOWN_PDF_USE_WEASYPRINT=1` only when a working native WeasyPrint environment is intentionally available.
9. **PDF generation fails after import:** inspect the renderer error and retry with the pip-only fpdf2 backend; do not report a successful PDF when the command failed.

## One-Shot Recipes

### Technical report

```bash
python .../render_markdown_pdf.py report.md -o report.pdf \
  --toc --title "Technical Report" --author "Team Name"
```

### Short memo

```bash
python .../render_markdown_pdf.py memo.md -o memo.pdf \
  --no-cover --title "Decision Memo"
```

### Branded output

```bash
python .../render_markdown_pdf.py input.md -o output.pdf \
  --css company-print.css --theme slate
```

## Verification Checklist

- [ ] Input Markdown and local assets were identified.
- [ ] `markdown`, `pygments`, and `fpdf2` import successfully.
- [ ] Metadata and cover/TOC choices are explicit.
- [ ] Renderer exited successfully and produced a `%PDF-` file.
- [ ] Title, headings, code, tables, and images were checked.
- [ ] Page count and selectable text were verified where tooling permits.
- [ ] Final absolute output path was reported.
