# Container / pip-only rendering notes

This reference records the reproducible path for Markdown documents in containers where OS package managers and native GUI libraries are unavailable.

## Install

```bash
python -m pip install markdown pygments fpdf2 pypdf
```

`pypdf` is optional but useful for verification. Do not require WeasyPrint or Chromium for the default path.

## Unicode fonts

The fpdf2 built-in Helvetica/Courier fonts are not Unicode-complete. For source containing typographic dashes, arrows, stars, or non-ASCII names, download or provide:

```text
.markdown-pdf-fonts/NotoSans-Regular.ttf
.markdown-pdf-fonts/NotoSans-Bold.ttf
```

Alternatively set:

```bash
export MARKDOWN_PDF_FONT_DIR=/path/to/font-directory
```

The renderer registers regular, bold, italic, and bold-italic variants from those two files. Keep font files local for reproducible builds.

## Mermaid and code blocks

The pip-only backend does not execute Mermaid. Mermaid fences remain readable code blocks. Because fpdf2's HTML `<pre>` path may use Courier, normalize unsupported symbols in the PDF-only HTML copy (`→` to `->`, `–` to `-`, `⭐` to `*`, and similar). Never mutate the source Markdown.

## Example

```bash
python scripts/render_markdown_pdf.py test.md \
  -o test.pdf \
  --toc \
  --title "AI Agent Frameworks – Terminal & Assistant Agents"
```

For a long report with a broad comparison table, use `--toc` and inspect page count plus extracted text. Remove `--html` intermediates after visual or source inspection unless the user explicitly requests HTML too.

## Verification

```bash
python - <<'PY'
from pathlib import Path
from pypdf import PdfReader
p = Path("test.pdf")
r = PdfReader(str(p))
text = "\n".join(page.extract_text() or "" for page in r.pages)
assert p.read_bytes()[:5] == b"%PDF-"
assert len(r.pages) > 0
assert text.strip()
print("pages=", len(r.pages), "text_chars=", len(text))
PY
```

Check the title, at least one body heading, and a representative table/code section—not only the PDF header.
