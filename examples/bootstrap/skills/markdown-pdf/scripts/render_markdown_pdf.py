#!/usr/bin/env python3
"""Render Markdown to a polished, selectable PDF with WeasyPrint."""
from __future__ import annotations

import argparse
import html
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

try:
    import markdown
    from markdown.extensions.toc import TocExtension
    from pygments.formatters import HtmlFormatter
except ImportError as exc:
    print(f"Missing dependency: {exc}. Install markdown pygments.", file=sys.stderr)
    raise SystemExit(2)

import os

try:
    if os.environ.get("MARKDOWN_PDF_USE_WEASYPRINT") == "1":
        from weasyprint import HTML as WeasyHTML
    else:
        WeasyHTML = None
except Exception:
    WeasyHTML = None
try:
    from playwright.sync_api import sync_playwright
except Exception:
    sync_playwright = None
try:
    from fpdf import FPDF
except Exception:
    FPDF = None

try:
    import yaml
except ImportError:
    yaml = None

ROOT = Path(__file__).resolve().parents[1]
CSS_PATH = ROOT / "templates" / "editorial.css"


def split_front_matter(text: str) -> tuple[dict[str, str], str]:
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---", 4)
    if end < 0:
        return {}, text
    raw = text[4:end]
    if yaml:
        data = yaml.safe_load(raw) or {}
        if isinstance(data, dict):
            return {str(k): str(v) for k, v in data.items() if v is not None}, text[end + 4:].lstrip("\n")
    data = {}
    for line in raw.splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            data[key.strip()] = value.strip().strip("\"'")
    return data, text[end + 4:].lstrip("\n")


def esc(value: str) -> str:
    return html.escape(str(value), quote=True)


def make_callouts(body: str) -> str:
    # Keep this deliberately narrow: only transform a complete blockquote whose first
    # line starts with a recognized label, preserving ordinary Markdown blockquotes.
    pattern = re.compile(r"<blockquote>\s*<p><strong>(Note|Tip|Warning|Important):</strong>(.*?)</p>(.*?)</blockquote>", re.S | re.I)
    def repl(m: re.Match[str]) -> str:
        kind = m.group(1).lower()
        return f'<aside class="callout {kind}"><strong>{m.group(1)}:</strong>{m.group(2)}{m.group(3)}</aside>'
    return pattern.sub(repl, body)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input", type=Path)
    ap.add_argument("-o", "--output", type=Path, required=True)
    ap.add_argument("--title")
    ap.add_argument("--subtitle")
    ap.add_argument("--author")
    ap.add_argument("--organization")
    ap.add_argument("--date")
    ap.add_argument("--version")
    ap.add_argument("--theme", choices=["indigo", "forest", "slate"], default="indigo")
    ap.add_argument("--css", action="append", type=Path, default=[])
    ap.add_argument("--toc", action="store_true")
    ap.add_argument("--no-cover", action="store_true")
    ap.add_argument("--html", type=Path, help="also save the intermediate HTML")
    args = ap.parse_args()

    source = args.input.expanduser().resolve()
    if not source.is_file():
        print(f"Input does not exist: {source}", file=sys.stderr)
        return 2
    meta, text = split_front_matter(source.read_text(encoding="utf-8"))
    for key in ("title", "subtitle", "author", "organization", "date", "version"):
        value = getattr(args, key)
        if value is not None:
            meta[key] = value
    title = meta.get("title", source.stem.replace("-", " ").replace("_", " ").title())

    extensions = ["extra", "attr_list", "sane_lists", "smarty", "fenced_code", "tables", TocExtension(baselevel=2, toc_depth="2-4")]
    body = markdown.markdown(text, extensions=extensions, output_format="html5")
    body = make_callouts(body)
    toc = ""
    if args.toc:
        toc = '<section class="toc"><h2>Contents</h2><div class="toc-list">' + markdown.markdown(text, extensions=[TocExtension(baselevel=2, toc_depth="2-4")]).split("<h2", 1)[0] + "</div></section>"
        # The extension's toc HTML is available from a separate Markdown instance.
        md_toc = markdown.Markdown(extensions=[TocExtension(baselevel=2, toc_depth="2-4")])
        md_toc.convert(text)
        toc = f'<section class="toc"><h2>Contents</h2>{md_toc.toc}</section>'

    formatter = HtmlFormatter(style="friendly", cssclass="highlight")
    css = CSS_PATH.read_text(encoding="utf-8")
    css += "\n" + formatter.get_style_defs(".highlight")
    css += f"\n:root {{ --accent: {'#0f766e' if args.theme == 'forest' else '#475569' if args.theme == 'slate' else '#4f46e5'}; }}\n"
    for path in args.css:
        css += "\n" + path.expanduser().resolve().read_text(encoding="utf-8")

    cover = ""
    if not args.no_cover:
        details = " · ".join(esc(meta[k]) for k in ("author", "organization", "date", "version") if meta.get(k))
        cover = f'<section class="cover"><div class="cover-rule"></div><p class="eyebrow">{esc(meta.get("organization", "DOCUMENT"))}</p><h1>{esc(title)}</h1>'
        if meta.get("subtitle"): cover += f'<p class="subtitle">{esc(meta["subtitle"])}</p>'
        if details: cover += f'<p class="cover-meta">{details}</p>'
        cover += '</section><div class="page-break"></div>'

    html_doc = f'''<!doctype html><html><head><meta charset="utf-8"><title>{esc(title)}</title><meta name="author" content="{esc(meta.get("author", ""))}"><style>{css}</style></head><body class="theme-{args.theme}"><header class="running-header">{esc(title)}</header><footer class="running-footer"><span>{esc(meta.get("organization", ""))}</span><span class="page-number"></span></footer>{cover}{toc}<main>{body}</main></body></html>'''
    output = args.output.expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    base_url = source.parent.as_uri() + "/"
    if args.html:
        args.html.expanduser().resolve().write_text(html_doc, encoding="utf-8")
    try:
        if WeasyHTML is not None:
            WeasyHTML(string=html_doc, base_url=base_url).write_pdf(str(output), metadata={"title": title, "author": meta.get("author", "")})
        elif FPDF is not None:
            class MarkdownPDF(FPDF):
                def header(self):
                    if self.page_no() > 1:
                        self.set_font(getattr(self, "pdf_family", "Helvetica"), size=8)
                        self.set_text_color(100, 116, 139)
                        self.cell(0, 7, title, new_x="LMARGIN", new_y="NEXT")
                        self.line(18, 16, 192, 16)
                        self.ln(3)
                def footer(self):
                    self.set_y(-14)
                    self.set_font(getattr(self, "pdf_family", "Helvetica"), size=8)
                    self.set_text_color(100, 116, 139)
                    self.cell(0, 8, f"{meta.get('organization', '')}   |   Page {self.page_no()}", align="C")
            pdf = MarkdownPDF(format="A4")
            font_dir = Path(os.environ.get("MARKDOWN_PDF_FONT_DIR", "/workspace/.markdown-pdf-fonts"))
            regular_font = font_dir / "NotoSans-Regular.ttf"
            bold_font = font_dir / "NotoSans-Bold.ttf"
            if regular_font.is_file() and bold_font.is_file():
                pdf.add_font("NotoSans", style="", fname=str(regular_font))
                pdf.add_font("NotoSans", style="B", fname=str(bold_font))
                pdf.add_font("NotoSans", style="I", fname=str(regular_font))
                pdf.add_font("NotoSans", style="BI", fname=str(bold_font))
                family = "NotoSans"
            else:
                family = "Helvetica"
            pdf.pdf_family = family
            pdf.set_margins(18, 18, 18)
            pdf.set_auto_page_break(True, margin=18)
            pdf.add_page()
            pdf.set_fill_color(79, 70, 229)
            pdf.rect(18, 35, 32, 3, style="F")
            pdf.set_text_color(79, 70, 229)
            pdf.set_font(family, "B", 11)
            pdf.ln(42)
            pdf.cell(0, 8, str(meta.get("organization", "DOCUMENT")).upper(), new_x="LMARGIN", new_y="NEXT")
            pdf.set_text_color(16, 24, 40)
            pdf.set_font(family, "B", 30)
            pdf.set_x(pdf.l_margin)
            pdf.multi_cell(0, 14, title)
            if meta.get("subtitle"):
                pdf.set_x(pdf.l_margin)
                pdf.set_text_color(100, 116, 139)
                pdf.set_font(family, size=16)
                pdf.multi_cell(0, 9, meta["subtitle"])
            pdf.set_y(250)
            pdf.set_font(family, size=9)
            pdf.cell(0, 6, " | ".join(str(meta[k]) for k in ("author", "organization", "date", "version") if meta.get(k)))
            import re
            fpdf_body = re.sub(r'\s+id="[^"]+"', "", body)
            fpdf_body = re.sub(r'<aside[^>]*>', '<blockquote>', fpdf_body)
            fpdf_body = fpdf_body.replace("→", "->").replace("←", "<-").replace("–", "-").replace("—", "--").replace("≤", "<=").replace("≥", ">=").replace("⭐", "*")
            fpdf_body = fpdf_body.replace('</aside>', '</blockquote>')
            fpdf_body = re.sub(r'<a[^>]*>(.*?)</a>', r'\1', fpdf_body, flags=re.S)
            fpdf_toc = re.sub(r'<a[^>]*>(.*?)</a>', r'\1', md_toc.toc if 'md_toc' in locals() else "", flags=re.S)
            fpdf_toc = re.sub(r'\s+href="[^"]+"', "", fpdf_toc)
            if args.toc:
                pdf.add_page()
                pdf.set_text_color(16, 24, 40)
                pdf.set_font(family, "B", 18)
                pdf.cell(0, 10, "Contents", new_x="LMARGIN", new_y="NEXT")
                pdf.set_font(family, size=10)
                pdf.write_html(fpdf_toc)
            pdf.add_page()
            pdf.set_text_color(23, 32, 51)
            pdf.set_font(family, size=10)
            pdf.write_html(fpdf_body)
            pdf.output(str(output))
        elif sync_playwright is not None:
            with sync_playwright() as p:
                browser = p.chromium.launch()
                page = browser.new_page()
                page.set_content(html_doc, wait_until="load")
                page.pdf(path=str(output), format="A4", print_background=True, prefer_css_page_size=True)
                browser.close()
        else:
            raise RuntimeError("Neither WeasyPrint nor Playwright is available")
    except Exception as exc:
        print(f"PDF generation failed: {exc}", file=sys.stderr)
        return 1
    print(f"Wrote {output} ({output.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
