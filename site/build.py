#!/usr/bin/env python3
import html
import os
import re
import shutil
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

SITE = Path(__file__).resolve().parent
REPO = SITE.parent
GUIDE = REPO / "docs" / "guide"
DIST = SITE / "dist"
DOCS_OUT = DIST / "docs"
TEMPLATE = SITE / "templates" / "docs.html"
REPO_URL = "https://github.com/honeybeehq/scout"
BLOB = REPO_URL + "/blob/main/"

KEY_RE = re.compile(r"^(?:[⌃⌥⇧⌘]*(?:[A-Z0-9]|Tab|Space|Esc|Enter|Return|↩|⌫|↑|↓|←|→)|[⌃⌥⇧⌘]+|fn)$")


class BuildError(Exception):
    pass


def slugify(text):
    text = re.sub(r"<[^>]+>", "", text)
    text = html.unescape(text).strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


class Page:
    def __init__(self, slug, source):
        self.slug = slug
        self.source = source
        self.text = source.read_text(encoding="utf-8")
        match = re.search(r"^# (.+)$", self.text, re.M)
        if not match:
            raise BuildError(f"{source.relative_to(REPO)}: no level-1 heading")
        self.title = strip_inline(match.group(1))
        self.out_dir = DOCS_OUT if slug == "index" else DOCS_OUT / slug
        self.anchors = set()

    @property
    def out_file(self):
        return self.out_dir / "index.html"


def strip_inline(text):
    text = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    return re.sub(r"[`*_]", "", text)


class Renderer:
    def __init__(self, page, pages, assets):
        self.page = page
        self.pages = pages
        self.assets = assets
        self.errors = []
        self.used_ids = set()

    def rel(self, target_dir, file=""):
        path = os.path.relpath(target_dir, self.page.out_dir).replace(os.sep, "/")
        path = "" if path == "." else path + "/"
        return (path + file) or "./"

    def resolve_link(self, url, image=False):
        if re.match(r"^[a-z][a-z0-9+.-]*:", url, re.I) or url.startswith("//"):
            return url
        parts = urlsplit(url)
        if not parts.path:
            return url
        target = (self.page.source.parent / unquote(parts.path)).resolve()
        frag = "#" + parts.fragment if parts.fragment else ""
        if image:
            if not target.is_file():
                self.errors.append(f"missing image {url}")
                return url
            rel = target.relative_to(REPO).as_posix()
            name = "media/" + rel.replace("/", "_")
            self.assets[name] = target
            return self.rel(DOCS_OUT, name)
        if target.parent == GUIDE and target.suffix == ".md":
            other = self.pages.get(target.stem)
            if not other:
                self.errors.append(f"link to {url}, which is not in order.txt")
                return url
            return self.rel(other.out_dir) + frag
        try:
            rel = target.relative_to(REPO).as_posix()
        except ValueError:
            self.errors.append(f"link outside the repo: {url}")
            return url
        if not target.exists():
            self.errors.append(f"link to missing file {url}")
            return url
        if parts.fragment and target.suffix == ".md":
            headings = {slugify(h) for h in re.findall(r"^#{1,6} (.+)$", target.read_text(encoding="utf-8"), re.M)}
            if parts.fragment not in headings:
                self.errors.append(f"link to missing heading {url}")
        kind = "tree/main/" if target.is_dir() else "blob/main/"
        return f"{REPO_URL}/{kind}{rel}{frag}"

    def inline(self, text):
        stash = []

        def keep(value):
            stash.append(value)
            return f"\x00{len(stash) - 1}\x00"

        def code(m):
            body = m.group(2)
            if KEY_RE.match(body.strip()):
                return keep(f"<kbd>{html.escape(body)}</kbd>")
            return keep(f"<code>{html.escape(body)}</code>")

        text = re.sub(r"(`+)(.+?)\1", code, text)

        def image(m):
            return keep(f'<img src="{html.escape(self.resolve_link(m.group(2), image=True))}" alt="{html.escape(m.group(1))}">')

        text = re.sub(r"!\[([^\]]*)\]\(([^)\s]+)\)", image, text)

        def link(m):
            href = self.resolve_link(m.group(2))
            label = self.inline(m.group(1))
            external = href.startswith("http")
            attrs = ' rel="noopener"' if external else ""
            return keep(f'<a href="{html.escape(href)}"{attrs}>{label}</a>')

        text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, text)
        text = html.escape(text, quote=False)
        text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
        text = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", text)
        text = re.sub(r"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)", r"<em>\1</em>", text)
        while "\x00" in text:
            text = re.sub(r"\x00(\d+)\x00", lambda m: stash[int(m.group(1))], text)
        return text

    def heading_id(self, text):
        base = slugify(text) or "section"
        ident, n = base, 1
        while ident in self.used_ids:
            n += 1
            ident = f"{base}-{n}"
        self.used_ids.add(ident)
        return ident

    def render(self, text):
        lines = text.split("\n")
        out = []
        i = 0
        para = []

        def flush():
            if para:
                out.append(f"<p>{self.inline(' '.join(s.strip() for s in para))}</p>")
                para.clear()

        while i < len(lines):
            line = lines[i]
            if line.startswith("```"):
                flush()
                lang = line[3:].strip()
                body = []
                i += 1
                while i < len(lines) and not lines[i].startswith("```"):
                    body.append(lines[i])
                    i += 1
                if i == len(lines):
                    self.errors.append("unclosed code block")
                i += 1
                cls = f' class="language-{html.escape(lang)}"' if lang else ""
                out.append(f"<pre><code{cls}>{html.escape(chr(10).join(body))}</code></pre>")
                continue
            m = re.match(r"^(#{1,6}) (.+?)\s*#*$", line)
            if m:
                flush()
                level = len(m.group(1))
                content = self.inline(m.group(2))
                if level == 1:
                    out.append(f"<h1>{content}</h1>")
                else:
                    ident = self.heading_id(content)
                    out.append(f'<h{level} id="{ident}">{content}<a class="anchor" href="#{ident}" aria-label="Link to this section">#</a></h{level}>')
                i += 1
                continue
            if re.match(r"^\s*$", line):
                flush()
                i += 1
                continue
            if re.match(r"^(\*\*\*|---|___)\s*$", line):
                flush()
                out.append("<hr>")
                i += 1
                continue
            if line.startswith("|") and i + 1 < len(lines) and re.match(r"^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$", lines[i + 1]):
                flush()
                rows = []
                while i < len(lines) and lines[i].startswith("|"):
                    rows.append(lines[i])
                    i += 1
                out.append(self.table(rows))
                continue
            if line.startswith(">"):
                flush()
                quote = []
                while i < len(lines) and lines[i].startswith(">"):
                    quote.append(lines[i][1:].lstrip() if len(lines[i]) > 1 else "")
                    i += 1
                out.append(f"<blockquote>{self.render(chr(10).join(quote))}</blockquote>")
                continue
            if re.match(r"^(\s*)([-*+]|\d+\.) ", line):
                flush()
                block = []
                while i < len(lines) and (re.match(r"^(\s*)([-*+]|\d+\.) ", lines[i]) or (lines[i].startswith("  ") and lines[i].strip()) or (not lines[i].strip() and i + 1 < len(lines) and re.match(r"^\s+\S|^(\s*)([-*+]|\d+\.) ", lines[i + 1]))):
                    block.append(lines[i])
                    i += 1
                out.append(self.list(block))
                continue
            para.append(line)
            i += 1
        flush()
        return "\n".join(out)

    def list(self, lines):
        first = re.match(r"^(\s*)([-*+]|\d+\.) ", lines[0])
        indent = len(first.group(1))
        ordered = first.group(2)[0].isdigit()
        items = []
        for line in lines:
            m = re.match(r"^(\s*)([-*+]|\d+\.) (.*)$", line)
            if m and len(m.group(1)) == indent:
                items.append([m.group(3)])
            elif items:
                items[-1].append(line[indent:] if line.strip() else "")
        parts = []
        for item in items:
            head, rest = item[0], item[1:]
            while rest and not rest[-1].strip():
                rest.pop()
            body = self.inline(head)
            if rest:
                sub = [r[2:] if r.startswith("  ") else r for r in rest]
                inner = "\n".join(sub)
                spaced = any(not r.strip() for r in rest)
                body = (f"<p>{body}</p>" if spaced else body) + self.render(textwrap_dedent(inner))
            parts.append(f"<li>{body}</li>")
        tag = "ol" if ordered else "ul"
        return f"<{tag}>{''.join(parts)}</{tag}>"

    def table(self, rows):
        def cells(row):
            row = row.strip()
            if row.startswith("|"):
                row = row[1:]
            if row.endswith("|"):
                row = row[:-1]
            return [c.strip() for c in re.split(r"(?<!\\)\|", row)]

        head = cells(rows[0])
        aligns = []
        for spec in cells(rows[1]):
            if spec.startswith(":") and spec.endswith(":"):
                aligns.append(' style="text-align:center"')
            elif spec.endswith(":"):
                aligns.append(' style="text-align:right"')
            else:
                aligns.append("")
        out = ['<div class="table"><table><thead><tr>']
        for n, c in enumerate(head):
            out.append(f"<th{aligns[n] if n < len(aligns) else ''}>{self.inline(c)}</th>")
        out.append("</tr></thead><tbody>")
        for row in rows[2:]:
            out.append("<tr>")
            for n, c in enumerate(cells(row)):
                out.append(f"<td{aligns[n] if n < len(aligns) else ''}>{self.inline(c)}</td>")
            out.append("</tr>")
        out.append("</tbody></table></div>")
        return "".join(out)


def textwrap_dedent(text):
    lines = text.split("\n")
    widths = [len(l) - len(l.lstrip()) for l in lines if l.strip()]
    cut = min(widths) if widths else 0
    return "\n".join(l[cut:] for l in lines)


def load_pages():
    order_file = GUIDE / "order.txt"
    slugs = [s.strip() for s in order_file.read_text(encoding="utf-8").splitlines() if s.strip() and not s.startswith("#")]
    if not slugs or slugs[0] != "index":
        raise BuildError("docs/guide/order.txt must start with index")
    pages = {}
    for slug in slugs:
        source = GUIDE / f"{slug}.md"
        if not source.is_file():
            raise BuildError(f"order.txt names {slug}, but docs/guide/{slug}.md is missing")
        if slug in pages:
            raise BuildError(f"order.txt names {slug} twice")
        pages[slug] = Page(slug, source)
    unlisted = sorted(p.stem for p in GUIDE.glob("*.md") if p.stem not in pages)
    if unlisted:
        raise BuildError("not in docs/guide/order.txt: " + ", ".join(unlisted))
    return pages


def fill(template, values):
    def sub(m):
        key = m.group(1)
        if key not in values:
            raise BuildError(f"template uses unknown {{{{{key}}}}}")
        return values[key]

    return re.sub(r"\{\{(\w+)\}\}", sub, template)


def build():
    pages = load_pages()
    order = list(pages.values())
    template = TEMPLATE.read_text(encoding="utf-8")
    if DOCS_OUT.exists():
        shutil.rmtree(DOCS_OUT)
    DOCS_OUT.mkdir(parents=True)
    assets = {}
    errors = []
    for n, page in enumerate(order):
        r = Renderer(page, pages, assets)
        body = r.render(page.text)
        errors += [f"{page.source.relative_to(REPO)}: {e}" for e in r.errors]
        nav = []
        for other in order:
            current = ' aria-current="page"' if other is page else ""
            nav.append(f'<li><a href="{r.rel(other.out_dir)}"{current}>{html.escape(other.title)}</a></li>')
        prev_link = next_link = ""
        if n > 0:
            p = order[n - 1]
            prev_link = f'<a class="prev" href="{r.rel(p.out_dir)}" rel="prev"><span>Previous</span>{html.escape(p.title)}</a>'
        if n + 1 < len(order):
            q = order[n + 1]
            next_link = f'<a class="next" href="{r.rel(q.out_dir)}" rel="next"><span>Next</span>{html.escape(q.title)}</a>'
        root = r.rel(DIST)
        page_html = fill(template, {
            "title": html.escape(page.title),
            "site_title": "Scout docs" if page.slug != "index" else "Scout",
            "root": root,
            "docs": r.rel(DOCS_OUT),
            "assets": r.rel(DIST / "assets"),
            "nav": "\n".join(nav),
            "content": body,
            "prev": prev_link,
            "next": next_link,
            "source": f"{BLOB}docs/guide/{page.slug}.md",
            "repo": REPO_URL,
        })
        page.out_dir.mkdir(parents=True, exist_ok=True)
        page.out_file.write_text(page_html, encoding="utf-8")
    for name, src in assets.items():
        dest = DOCS_OUT / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)
    assets_out = DIST / "assets"
    assets_out.mkdir(parents=True, exist_ok=True)
    for src in (SITE / "assets").rglob("*"):
        if src.is_file() and not src.name.startswith("."):
            dest = assets_out / src.relative_to(SITE / "assets")
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest)
    landing = SITE / "index.html"
    if landing.is_file():
        shutil.copy2(landing, DIST / "index.html")
    else:
        (DIST / "index.html").write_text(
            '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Scout</title>'
            '<meta http-equiv="refresh" content="0; url=docs/"></head>'
            '<body><p><a href="docs/">Scout docs</a></p></body></html>\n', encoding="utf-8")
    return order, errors


class LinkCollector(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.ids = set()

    def handle_starttag(self, tag, attrs):
        for key, value in attrs:
            if key == "id" and value:
                self.ids.add(value)
            if key in ("href", "src") and value is not None:
                self.links.append((tag, value))


def parse(path, cache):
    if path not in cache:
        collector = LinkCollector()
        collector.feed(path.read_text(encoding="utf-8"))
        cache[path] = collector
    return cache[path]


def check_links(files):
    cache = {}
    broken = []
    checked = 0
    for file in files:
        for tag, url in parse(file, cache).links:
            if re.match(r"^[a-z][a-z0-9+.-]*:", url, re.I) or url.startswith("//"):
                continue
            checked += 1
            parts = urlsplit(url)
            if parts.path:
                target = (file.parent / unquote(parts.path)).resolve()
                if url.endswith("/") or target.is_dir():
                    target = target / "index.html"
            else:
                target = file
            try:
                target.relative_to(DIST.resolve())
            except ValueError:
                broken.append(f"{file.relative_to(DIST)}: {url} points outside site/dist")
                continue
            if not target.is_file():
                broken.append(f"{file.relative_to(DIST)}: {url} (no {target.relative_to(DIST.resolve())})")
                continue
            if parts.fragment and target.suffix == ".html" and parts.fragment not in parse(target, cache).ids:
                broken.append(f"{file.relative_to(DIST)}: {url} (no #{parts.fragment})")
    return checked, broken


def main():
    try:
        order, errors = build()
    except BuildError as e:
        print(f"build failed: {e}", file=sys.stderr)
        return 1
    files = [p.out_file for p in order] + [DIST / "index.html"]
    checked, broken = check_links(files)
    for line in errors + broken:
        print(f"broken: {line}", file=sys.stderr)
    for page in order:
        print(f"  {page.out_file.relative_to(SITE)}  {page.title}")
    print(f"{len(order)} pages, {checked} internal links checked, {len(errors) + len(broken)} broken")
    return 1 if errors or broken else 0


if __name__ == "__main__":
    sys.exit(main())
