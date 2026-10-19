#!/usr/bin/env python3
"""claudedoc: keep a markdown skeleton as the source of truth, let Claude fill
tagged blocks into sidecar snippets, render skeleton + snippets into <doc>.out.md.

Skeleton syntax (in doc.md):
  ```claude-command id=foo          multi-line prompt, replaced by snippet
  ...prompt...
  ```
  [claude id=bar] one-line prompt   inline; marker..EOL replaced by snippet
  foo [claude id=baz] prompt [/claude] bar    inline with explicit end

Layout:   doc.md  doc.out.md  doc.snippets/{<id>.md,<id>.prompt,.session,.linemap}

Subcommands:
  blocks FILE                 JSON list of {id,kind,line,end,prompt,status}
  render FILE [--markers]     write FILE.out.md (+ .linemap); print out path.
                              --markers adds <!-- claude id=.. --> above fenced results
  ask FILE ID [--force]       fill one block (cache unless prompt changed/--force);
                              live log of tool calls/text in <snippets>/<ID>.log
  ask-all FILE [--force]      fill every missing/stale block, then render
  new-id FILE                 print an unused id (c1, c2, ...)
  sessions                    JSON list of recent sessions for this cwd (id, mtime, first prompt)
  link FILE [ID] [--shared]   link asks to an existing claude session (default: most recent
                              for cwd). Default forks it on first ask so the interactive
                              session is untouched; --shared appends to the very same session.
  unlink FILE                 forget the session (next ask starts fresh)
"""
import json
import os
import re
import signal
import subprocess
import sys
from pathlib import Path

FENCE_RE = re.compile(r"^```claude-command\s+id=([A-Za-z0-9_.-]+)\s*$")
INLINE_RE = re.compile(r"\[claude id=([A-Za-z0-9_.-]+)\]\s?(.*?)(?:\s?\[/claude\]|$)")

CLAUDE_FLAGS = os.environ.get("CLAUDEDOC_FLAGS", "--dangerously-skip-permissions").split()
MODEL = os.environ.get("CLAUDEDOC_MODEL")  # None -> CLI default

SYSTEM = """You are filling ONE block of a markdown document the user is writing in vim.
You receive the whole document for context; the block to fill is delimited by
<<<CLAUDE-TARGET id=...>>> and <<<END-TARGET>>>, and its instructions are inside.
Other blocks may already be filled or still contain instructions; ignore them.

Rules:
- Output ONLY the text that replaces the block. No preamble, no explanation,
  no closing remarks, no code fence wrapping the whole answer.
- Match the document's tone, heading level and markdown style. Do not repeat
  surrounding headings or text.
- For an inline block ([claude id=...]) answer in a single line.
- Use your tools (Slack, Confluence, Glean, local files) when the
  instruction asks for links, facts or quotes; cite with real URLs. Never
  invent links, names, dates or numbers. If you cannot find something, say so
  in one short bracketed note like [could not find: ...].
- You are a subagent. Don't run memo."""


# ----------------------------------------------------------------- parsing
def paths(doc):
    doc = Path(doc).resolve()
    stem = doc.with_suffix("")
    return doc, Path(str(stem) + ".out.md"), Path(str(stem) + ".snippets")


def parse(lines):
    """Return list of blocks: dict(id, kind, line, end, prompt, indent).
    line/end are 0-based inclusive. For inline, 'col' is the marker column."""
    blocks, i = [], 0
    while i < len(lines):
        m = FENCE_RE.match(lines[i].strip())
        if m and lines[i].lstrip().startswith("```"):
            indent = lines[i][: len(lines[i]) - len(lines[i].lstrip())]
            j = i + 1
            while j < len(lines) and lines[j].strip() != "```":
                j += 1
            prompt = "\n".join(l[len(indent):] if l.startswith(indent) else l for l in lines[i + 1 : j]).strip()
            blocks.append(dict(id=m.group(1), kind="fence", line=i, end=min(j, len(lines) - 1), prompt=prompt, indent=indent))
            i = j + 1
            continue
        for m in INLINE_RE.finditer(lines[i]):
            blocks.append(dict(id=m.group(1), kind="inline", line=i, end=i, prompt=m.group(2).strip(),
                               col=m.start(), end_col=m.end()))
        i += 1
    return blocks


def status(snips, b):
    md, pr = snips / f"{b['id']}.md", snips / f"{b['id']}.prompt"
    if not md.exists():
        return "missing"
    if pr.exists() and pr.read_text().strip() != b["prompt"]:
        return "stale"
    return "cached"


# ----------------------------------------------------------------- render
def render_lines(lines, blocks, snips, target=None, markers=True):
    """Return (out_lines, linemap). target=id -> wrap that block with TARGET markers
    instead of substituting it."""
    out, linemap, i = [], [], 0
    by_line = {}
    for b in blocks:
        by_line.setdefault(b["line"], []).append(b)
    while i < len(lines):
        bs = by_line.get(i)
        if not bs:
            out.append(lines[i]); i += 1; continue
        b = bs[0]
        if b["kind"] == "inline":
            # rebuild the line piecewise; several markers may share one line
            if target in {x["id"] for x in bs}:
                linemap.append([i, len(out), target])
                out.append(f"<<<CLAUDE-TARGET id={target} kind=inline>>>")
                out.append(lines[i])
                out.append("<<<END-TARGET>>>")
            else:
                line, pos = "", 0
                for x in bs:
                    snip = snips / f"{x['id']}.md"
                    line += lines[i][pos:x["col"]]
                    start = len(line)
                    if snip.exists():
                        line += " ".join(snip.read_text().split())
                    else:
                        line += lines[i][x["col"]:x["end_col"]]
                    # [skel_line, out_line, id, out_col_start, out_col_end] (0-based, byte cols)
                    linemap.append([i, len(out), x["id"], start, len(line)])
                    pos = x["end_col"]
                out.append(line + lines[i][pos:])
            i += 1
            continue
        linemap.append([b["line"], len(out), b["id"]])
        snip = snips / f"{b['id']}.md"
        if target == b["id"]:
            out.append(f"<<<CLAUDE-TARGET id={b['id']} kind=fence>>>")
            out.append(b["prompt"])
            out.append("<<<END-TARGET>>>")
        elif not snip.exists():
            out.extend(lines[i : b["end"] + 1])
        else:
            text = snip.read_text().rstrip("\n")
            if markers:
                out.append(f"{b['indent']}<!-- claude id={b['id']} -->")
            out.extend(b["indent"] + l if l else l for l in text.split("\n"))
        i = b["end"] + 1
    return out, linemap


def cmd_render(doc, markers=False):
    doc, out, snips = paths(doc)
    lines = doc.read_text().split("\n")
    blocks = parse(lines)
    out_lines, linemap = render_lines(lines, blocks, snips, markers=markers)
    out.write_text("\n".join(out_lines))
    if snips.exists() or blocks:
        snips.mkdir(exist_ok=True)
        (snips / ".linemap").write_text(json.dumps(linemap))
    print(out)


# ----------------------------------------------------------------- ask
def _log_event(log, d):
    """Append one human-readable line per stream-json event."""
    t = d.get("type")
    if t == "assistant":
        for c in d.get("message", {}).get("content", []):
            k = c.get("type")
            if k == "text" and c.get("text", "").strip():
                log.write("\n[claude] " + c["text"].strip() + "\n")
            elif k == "tool_use":
                inp = c.get("input") or {}
                brief = inp.get("command") or inp.get("query") or inp.get("file_path") or inp.get("pattern") or inp.get("url") or inp.get("prompt") or inp.get("description") or ""
                brief = " ".join(str(brief).split())[:160]
                log.write(f"[tool] {c.get('name')}  {brief}\n")
            elif k == "thinking":
                log.write("[thinking]\n")
    elif t == "user":
        for c in d.get("message", {}).get("content", []):
            if isinstance(c, dict) and c.get("type") == "tool_result":
                body = c.get("content")
                if isinstance(body, list):
                    body = " ".join(x.get("text", "") for x in body if isinstance(x, dict))
                body = " ".join(str(body or "").split())
                log.write(f"   -> {body[:200]}\n")
    elif t == "system" and d.get("subtype") == "init":
        log.write(f"[session] {d.get('session_id')}  model={d.get('model')}\n")
    elif t == "result":
        log.write(f"\n[done] {d.get('subtype')}  {d.get('duration_ms', 0) / 1000:.1f}s  ${d.get('total_cost_usd', 0):.3f}\n")
    log.flush()


def call_claude(prompt, cwd, snips, bid):
    sess_file, log_file = snips / ".session", snips / f"{bid}.log"
    base = ["claude", "-p", "--verbose", "--output-format", "stream-json", *CLAUDE_FLAGS, "--append-system-prompt", SYSTEM]
    if MODEL:
        base += ["--model", MODEL]
    raw = sess_file.read_text().strip() if sess_file.exists() else ""
    fork, sid = raw.startswith("fork:"), raw.removeprefix("fork:") or None

    def attempt(resume):
        cmd = list(base)
        if resume:
            cmd += ["--resume", resume]
            if fork:
                cmd += ["--fork-session"]
        result, errtail = None, []
        with log_file.open("w") as log:
            log.write(f"[ask] id={bid}  resume={resume or '-'}{' (fork)' if resume and fork else ''}\n")
            p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=cwd)

            def _cancel(*_):
                log.write("\n[cancelled]\n"); log.flush()
                p.kill()
                sys.exit(130)

            signal.signal(signal.SIGTERM, _cancel)
            signal.signal(signal.SIGINT, _cancel)
            p.stdin.write(prompt); p.stdin.close()
            for line in p.stdout:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                _log_event(log, d)
                if d.get("type") == "result":
                    result = d
            errtail = p.stderr.read()[-2000:]
            code = p.wait()
            if code != 0 or result is None:
                log.write(f"[error] exit={code} {errtail}\n")
        return code, result, errtail

    code, result, err = attempt(sid)
    if (code != 0 or result is None) and sid:  # stale session: retry fresh
        code, result, err = attempt(None)
    if code != 0 or result is None:
        sys.exit(f"claude failed ({code}): {err.strip()}")
    if result.get("session_id"):
        sess_file.write_text(result["session_id"])
    return (result.get("result") or "").strip()


def fill(doc, lines, blocks, snips, b, force):
    st = status(snips, b)
    if st == "cached" and not force:
        return "cached"
    ctx, _ = render_lines(lines, blocks, snips, target=b["id"])
    prompt = (
        f"Document: {doc.name}\nFill the block id={b['id']} ({b['kind']}). "
        "Reply with only the replacement text.\n\n" + "\n".join(ctx)
    )
    text = call_claude(prompt, str(doc.parent), snips, b["id"])
    text = re.sub(r"^```[a-z]*\n(.*)\n```$", r"\1", text, flags=re.S)  # unwrap a stray fence
    (snips / f"{b['id']}.md").write_text(text + "\n")
    (snips / f"{b['id']}.prompt").write_text(b["prompt"] + "\n")
    return "generated"


def cmd_ask(doc, bid, force):
    doc, _, snips = paths(doc)
    lines = doc.read_text().split("\n")
    blocks = parse(lines)
    snips.mkdir(exist_ok=True)
    hits = [b for b in blocks if b["id"] == bid]
    if not hits:
        sys.exit(f"no block id={bid} in {doc.name}")
    print(json.dumps({"id": bid, "result": fill(doc, lines, blocks, snips, hits[0], force)}))
    cmd_render(doc)


def cmd_ask_all(doc, force):
    doc, _, snips = paths(doc)
    lines = doc.read_text().split("\n")
    blocks = parse(lines)
    snips.mkdir(exist_ok=True)
    res = {b["id"]: fill(doc, lines, blocks, snips, b, force) for b in blocks}
    print(json.dumps(res))
    cmd_render(doc)


def cmd_blocks(doc):
    doc, _, snips = paths(doc)
    lines = doc.read_text().split("\n")
    bs = parse(lines)
    for b in bs:
        b["status"] = status(snips, b)
        b["line"] += 1; b["end"] += 1  # 1-based for the editor
    print(json.dumps(bs))


def project_dir(cwd):
    slug = re.sub(r"[^A-Za-z0-9]", "-", str(Path(cwd).resolve()))
    return Path.home() / ".claude" / "projects" / slug


def cmd_sessions(cwd):
    out = []
    for f in sorted(project_dir(cwd).glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)[:15]:
        first = ""
        with f.open() as fh:
            for line in fh:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if d.get("type") != "user" or d.get("isMeta"):
                    continue
                c = d.get("message", {}).get("content")
                if isinstance(c, list):
                    c = " ".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
                t = " ".join(str(c or "").split())
                # skip slash commands, their output, system/tool noise
                if not t or t.startswith("<") or t.startswith("/"):
                    continue
                first = t[:100]
                break
        if first.startswith("Document: ") and "Fill the block id=" in first:
            first = "[claudedoc ask] " + first[len("Document: "):].split(" Fill the block")[0]
        out.append(dict(id=f.stem, mtime=int(f.stat().st_mtime), prompt=first or "(slash commands only)"))
    print(json.dumps(out))


def cmd_link(doc, sid, shared):
    doc, _, snips = paths(doc)
    snips.mkdir(exist_ok=True)
    if not sid:
        files = sorted(project_dir(doc.parent).glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
        if not files:
            sys.exit(f"no claude sessions found for {doc.parent}")
        sid = files[0].stem
    (snips / ".session").write_text(sid if shared else f"fork:{sid}")
    print(json.dumps({"linked": sid, "mode": "shared" if shared else "fork"}))


def cmd_unlink(doc):
    _, _, snips = paths(doc)
    f = snips / ".session"
    if f.exists():
        f.unlink()
    print(json.dumps({"linked": None}))


def cmd_new_id(doc):
    doc, _, _ = paths(doc)
    ids = {b["id"] for b in parse(doc.read_text().split("\n"))} if doc.exists() else set()
    n = 1
    while f"c{n}" in ids:
        n += 1
    print(f"c{n}")


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd, doc, rest = argv[0], argv[1], argv[2:]
    force, shared = "--force" in rest, "--shared" in rest
    rest = [r for r in rest if r not in ("--force", "--shared")]
    if cmd == "sessions":
        return cmd_sessions(doc)  # here `doc` is the cwd
    if cmd == "link":
        return cmd_link(doc, rest[0] if rest else None, shared)
    if cmd == "unlink":
        return cmd_unlink(doc)
    if cmd == "blocks":
        cmd_blocks(doc)
    elif cmd == "render":
        cmd_render(doc, markers="--markers" in rest)
    elif cmd == "ask":
        cmd_ask(doc, rest[0], force)
    elif cmd == "ask-all":
        cmd_ask_all(doc, force)
    elif cmd == "new-id":
        cmd_new_id(doc)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
