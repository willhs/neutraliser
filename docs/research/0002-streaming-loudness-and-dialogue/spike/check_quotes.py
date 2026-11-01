#!/usr/bin/env python3
"""Check every quotation the research note cites against the source's own text.

The web research came back through a summarising fetch model, which is known to misread digits, so its quotes
can't be trusted until matched against raw text. This fetches each source once, extracts its text, and looks for
each quote after normalising whitespace, dashes, quote marks and soft hyphens.

Usage: check_quotes.py <quotes.tsv> <cache dir> <out.tsv> <pkgs dir>
quotes.tsv columns: id, url, quote. The cache dir is for downloads and must not hold scripts.
A row's URL may start with "jina:", meaning read it through the r.jina.ai text extractor (JS-only pages).
"""
import hashlib
import html
import re
import subprocess
import sys
from pathlib import Path

quotes_path, cache, out_path = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
sys.path.append(sys.argv[4])
from pypdf import PdfReader  # noqa: E402

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"


def fetch(url):
    cache.mkdir(parents=True, exist_ok=True)
    path = cache / hashlib.sha1(url.encode()).hexdigest()
    if path.exists() and path.stat().st_size > 0:
        return path
    target = "https://r.jina.ai/" + url[5:] if url.startswith("jina:") else url
    subprocess.run(["curl", "-sSL", "--compressed", "--max-time", "120", "-A", UA, "-o", str(path), target], check=False)
    return path


def normalise(text):
    text = html.unescape(text).replace("­", "")
    # A line break can split a word in extracted PDFs.
    text = re.sub(r"(\w)-\s*\n\s*(\w)", r"\1\2", text)
    for dash in "‐‑‒–—―−":
        text = text.replace(dash, "-")
    for quote in "‘’‚′":
        text = text.replace(quote, "'")
    for quote in "“”„″":
        text = text.replace(quote, '"')
    text = text.replace(" ", " ").replace("\\_", "_").replace("**", "").replace("`", "")
    return re.sub(r"\s+", " ", text).lower()


def text_of(path):
    raw = path.read_bytes()
    if raw[:5] == b"%PDF-":
        pages = PdfReader(str(path)).pages
        return "\n".join(page.extract_text() or "" for page in pages)
    text = raw.decode("utf-8", "replace")
    stripped = re.sub(r"<[^>]+>", " ", re.sub(r"(?is)<(script|style)\b.*?</\1>", " ", text))
    # Keep the raw text too: tag-stripping eats source code, where < and > are comparisons.
    return stripped + "\n" + text


texts = {}
rows, failures = [], 0
for line in quotes_path.read_text().splitlines():
    if not line.strip() or line.startswith("id\t"):
        continue
    qid, url, quote = line.split("\t")
    if url not in texts:
        try:
            path = fetch(url)
            texts[url] = normalise(text_of(path))
        except Exception as error:  # a bad source is a result to report, not a crash
            texts[url] = ""
            print(f"could not read {url}: {error}", file=sys.stderr)
    found = normalise(quote) in texts[url]
    status = "ok" if found else ("no-text" if len(texts[url]) < 500 else "NOT-FOUND")
    failures += 0 if found else 1
    rows.append("\t".join([qid, status, str(len(texts[url])), url, quote]))

out_path.write_text("id\tstatus\tsource_chars\turl\tquote\n" + "\n".join(rows) + "\n")
print(f"{len(rows) - failures}/{len(rows)} quotes found")
for row in rows:
    if "\tok\t" not in row:
        print(row)
