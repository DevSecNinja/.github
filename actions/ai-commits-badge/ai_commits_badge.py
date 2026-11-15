#!/usr/bin/env python3
"""Render an "AI commits" README badge from commit authors and Co-authored-by trailers.

Needs only git + Python 3.8+. Merge commits and bot automation are excluded.
Outputs in --out: ai-commits.svg, ai-commits.json (Shields endpoint),
ai-commits-stats.json and ai-commits-card.svg (auto light/dark).
"""
import argparse
import json
import re
import subprocess
from collections import Counter
from datetime import datetime, timezone
from html import escape
from pathlib import Path

# Complete name/email patterns; first matching tool wins for authors and trailers.
AI_IDENTITIES = [
    (r"copilot-swe-agent(?:\[bot\])?", r"198982749\+Copilot@users\.noreply\.github\.com", "Copilot coding agent"),
    (None, r"223556219\+Copilot@users\.noreply\.github\.com", "Copilot CLI"),
    (None, r"175728472\+Copilot@users\.noreply\.github\.com", "Copilot"),
    (r"anthropic-code-agent(?:\[bot\])?", r"242468646\+Claude@users\.noreply\.github\.com", "Claude agent"),
    (None, r"noreply@anthropic\.com", "Claude Code"),
    (None, r"cursoragent@cursor\.com", "Cursor"),
    (r"devin-ai-integration\[bot\]", None, "Devin"),
    (r"google-labs-jules\[bot\]", None, "Jules"),
    (None, r"noreply@aider\.chat", "Aider"),
]
NO_ATTRIBUTION = "No recorded AI attribution"
SEGMENTS = [
    ("agent", "AI agent", "#8250df"),
    ("coauthored", "co-authored with AI", "#c297ff"),
    ("unattributed", NO_ATTRIBUTION, "#0969da"),
]
PURPLE, GREY = "#8250df", "#8c959f"
SPARKLE = "M5 0 6.2 3.8 10 5 6.2 6.2 5 10 3.8 6.2 0 5 3.8 3.8Z"
VERDANA = {" ": 3.9, "%": 11.9, "/": 4.7, "I": 4.6, "A": 7.5, "i": 3.1, "m": 10.7, "t": 4.3,
           "s": 5.7, "c": 5.7, "o": 6.7, "n": 7.0, "a": 6.6}


def text_width(s):
    return sum(VERDANA.get(ch, 7.0 if ch.isdigit() else 6.6) for ch in s)


def ai_tool(identity):
    match = re.fullmatch(r"\s*(.*?)\s*<([^<>]+)>\s*", identity)
    if not match:
        return None
    name, email = (part.strip() for part in match.groups())
    for name_pattern, email_pattern, tool in AI_IDENTITIES:
        if (name_pattern and re.fullmatch(name_pattern, name, re.IGNORECASE)) or (
            email_pattern and re.fullmatch(email_pattern, email, re.IGNORECASE)
        ):
            return tool
    return None


def git(repo_dir, *args):
    return subprocess.run(
        ["git", "-C", str(repo_dir), *args], check=True,
        capture_output=True, text=True, encoding="utf-8",
    ).stdout


def collect(repo_dir, ref, since):
    if git(repo_dir, "rev-parse", "--is-shallow-repository").strip() == "true":
        raise ValueError(
            "Shallow history cannot be measured accurately. "
            "Use actions/checkout with fetch-depth: 0, or git fetch --unshallow."
        )
    revision = git(repo_dir, "rev-parse", "--verify", "--end-of-options", ref + "^{commit}").strip()
    fmt = "%an <%ae>%x1f%(trailers:key=Co-authored-by,valueonly,separator=%x1e)%x00"
    cmd = ["log", "--no-show-signature", "--no-merges", f"--format={fmt}"]
    if since:
        cmd.append(f"--since={since}")
    out = git(repo_dir, *cmd, revision, "--")
    counts, tools = Counter(), Counter()
    for record in filter(None, (r.strip("\n") for r in out.split("\0"))):
        author, _, trailers = record.partition("\x1f")
        if tool := ai_tool(author):
            counts["agent"] += 1
            tools[tool] += 1
        elif "[bot]" in author:
            counts["automation"] += 1
        elif co := next(filter(None, map(ai_tool, trailers.split("\x1e"))), None):
            counts["coauthored"] += 1
            tools[co] += 1
        else:
            counts["unattributed"] += 1
    considered = counts["agent"] + counts["coauthored"] + counts["unattributed"]
    ai = counts["agent"] + counts["coauthored"]
    return {
        "source": "commit-authors-and-trailers",
        "ref": ref,
        "since": since,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "commits": considered,
        "ai_commits": ai,
        "ai_percent": round(100 * ai / considered, 1) if considered else None,
        "agent": counts["agent"],
        "coauthored": counts["coauthored"],
        "unattributed": counts["unattributed"],
        "excluded_automation": counts["automation"],
        "tools": dict(tools.most_common()),
    }


def message(st):
    return "n/a" if not st["commits"] else f"{100 * st['ai_commits'] / st['commits']:.0f}%"


def tooltip(st, name):
    if not st["commits"]:
        return f"{name}: no commits to measure"
    window = f" since {st['since']}" if st["since"] else ""
    by_tool = ", ".join(f"{t} {n}" for t, n in st["tools"].items()) or "none"
    return (f"{name}: {st['ai_commits']:,} of {st['commits']:,} commits{window} ({message(st)}) involved AI: "
            f"{st['agent']:,} by an AI agent, {st['coauthored']:,} co-authored with AI, "
            f"{st['unattributed']:,} {NO_ATTRIBUTION}. "
            f"By tool: {by_tool}. Excludes merges and {st['excluded_automation']:,} bot-automation commits.")


def badge_svg(st, name, label="AI commits"):
    msg = message(st)
    lw = round(text_width(label) + 10 + 14)
    rw = round(text_width(msg) + 10)
    w = lw + rw
    title = escape(tooltip(st, name))
    strip, x = [], 0.0
    for key, _, colour in SEGMENTS:
        seg = w * st[key] / st["commits"] if st["commits"] else 0
        if seg > 0:
            strip.append(f'<rect x="{x:.2f}" y="17" width="{seg + 0.01:.2f}" height="3" fill="{colour}"/>')
            x += seg

    def txt(cx, t):
        tl = text_width(t) * 10
        return (f'<text x="{cx * 10:.0f}" y="135" fill="#010101" fill-opacity=".3" transform="scale(.1)" '
                f'textLength="{tl:.0f}">{escape(t)}</text>'
                f'<text x="{cx * 10:.0f}" y="125" transform="scale(.1)" fill="#fff" '
                f'textLength="{tl:.0f}">{escape(t)}</text>')

    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="20" role="img" aria-label="{title}">'
        f"<title>{title}</title>"
        '<linearGradient id="s" x2="0" y2="100%"><stop offset="0" stop-color="#bbb" stop-opacity=".1"/>'
        '<stop offset="1" stop-opacity=".1"/></linearGradient>'
        f'<clipPath id="r"><rect width="{w}" height="20" rx="3" fill="#fff"/></clipPath>'
        f'<g clip-path="url(#r)"><rect width="{lw}" height="20" fill="#555"/>'
        f'<rect x="{lw}" width="{rw}" height="20" fill="{PURPLE if st["commits"] else GREY}"/>'
        f'{"".join(strip)}<rect width="{w}" height="20" fill="url(#s)"/></g>'
        f'<path d="{SPARKLE}" transform="translate(5 3.5)" fill="#fff"/>'
        '<g text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="110" '
        'text-rendering="geometricPrecision">'
        f"{txt(14 + (lw - 14) / 2, label)}{txt(lw + rw / 2, msg)}</g></svg>"
    )


CARD_THEMES = {
    "light": ".bg{fill:#fff;stroke:#d0d7de}.t{fill:#1f2328}.m{fill:#59636e}",
    "dark": ".bg{fill:#0d1117;stroke:#3d444d}.t{fill:#f0f6fc}.m{fill:#9198a1}",
}
CARD_LEGEND = {"agent": "AI agent", "coauthored": "Co-authored", "unattributed": NO_ATTRIBUTION}


def fits(s, font_px, max_w):
    # Shorten lines instead of squeezing them with textLength.
    return len(s) * font_px * 0.55 <= max_w


def legend_label(key, share):
    for label in (CARD_LEGEND[key], "No recorded AI"):
        if fits(f"{label} {share}", 12, 129):
            return label
    return "No AI record"


def tools_line(tools, max_w=432):
    items = list(tools.items())
    for k in range(len(items), 0, -1):
        more = len(items) - k
        line = "Tools: " + " · ".join(f"{t} {c:,}" for t, c in items[:k]) + (f" · +{more} more" if more else "")
        if fits(line, 12, max_w):
            return line
    return f"Tools: {len(items)} detected" if items else "Tools: none detected"


def card_svg(st, name, theme="auto"):
    css = CARD_THEMES["dark" if theme == "dark" else "light"]
    if theme == "auto":
        css += "@media (prefers-color-scheme:dark){" + CARD_THEMES["dark"] + "}"
    css += 'text{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans",Helvetica,Arial,sans-serif}'
    n = st["commits"]
    window = f" since {st['since']}" if st["since"] else ""
    sub = f"of {n:,} commits{window} involved AI" if n else "no commits to measure"
    shown_name = name if fits(name, 12, 200) else name.rsplit("/", 1)[-1]
    bar, legend, x = [], [], 24.0
    for i, (key, _, colour) in enumerate(SEGMENTS):
        w = 432 * st[key] / n if n else 0
        if w > 0:
            bar.append(f'<rect x="{x:.2f}" y="88" width="{w + 0.01:.2f}" height="10" fill="{colour}"/>')
            x += w
        share = f"{100 * st[key] / n:.0f}%" if n else "0%"
        lx = 24 + i * 144
        legend.append(f'<circle cx="{lx + 5}" cy="117" r="5" fill="{colour}"/>'
                      f'<text x="{lx + 15}" y="121" font-size="12" class="t">{legend_label(key, share)} '
                      f'<tspan font-weight="600">{share}</tspan></text>')
    title = escape(tooltip(st, name))
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="480" height="190" viewBox="0 0 480 190" role="img" '
        f'aria-label="{title}"><title>{title}</title><style>{css}</style>'
        '<rect class="bg" x=".5" y=".5" width="479" height="189" rx="8"/>'
        f'<path d="{SPARKLE}" transform="translate(24 21) scale(1.4)" fill="{PURPLE}"/>'
        '<text x="46" y="34" font-size="15" font-weight="600" class="t">Who wrote the commits?</text>'
        f'<text x="456" y="34" font-size="12" text-anchor="end" class="m">{escape(shown_name)}</text>'
        f'<text x="24" y="74"><tspan font-size="28" font-weight="700" fill="{PURPLE if n else GREY}">'
        f'{escape(message(st))}</tspan><tspan dx="10" font-size="13" class="m">{escape(sub)}</tspan></text>'
        '<clipPath id="bar"><rect x="24" y="88" width="432" height="10" rx="5"/></clipPath>'
        f'<g clip-path="url(#bar)"><rect x="24" y="88" width="432" height="10" fill="{GREY}" opacity=".25"/>'
        f'{"".join(bar)}</g>{"".join(legend)}'
        f'<text x="24" y="149" font-size="12" class="m">{escape(tools_line(st["tools"]))}</text>'
        '<text x="24" y="172" font-size="11" class="m">Commit authors + Co-authored-by trailers · bots excluded</text>'
        f'<text x="456" y="172" font-size="11" text-anchor="end" class="m">{st["generated_at"][:10]}</text>'
        "</svg>"
    )


def endpoint_json(st, label="AI commits"):
    logo = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><path d="{SPARKLE}" fill="#fff"/></svg>'
    return {"schemaVersion": 1, "label": label, "message": message(st),
            "color": PURPLE.lstrip("#") if st["commits"] else "lightgrey", "logoSvg": logo}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo-dir", default=".")
    ap.add_argument("--ref", default="HEAD")
    ap.add_argument("--since", help='only count recent commits, e.g. "90 days ago"')
    ap.add_argument("--name", default="this repository", help="owner/repo shown in the tooltip")
    ap.add_argument("--label", default="AI commits")
    ap.add_argument("--out", default="badges")
    ap.add_argument("--themes", action="store_true",
                    help="also write ai-commits-card-light.svg / -dark.svg for <picture> tags")
    ap.add_argument("--github-output", help="append numeric step outputs to this file")
    args = ap.parse_args()
    try:
        st = collect(args.repo_dir, args.ref, args.since)
    except (ValueError, subprocess.CalledProcessError) as error:
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) else str(error)
        ap.exit(1, f"AI commits badge: {detail}\n")
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    files = {
        "ai-commits.svg": badge_svg(st, args.name, args.label),
        "ai-commits.json": json.dumps(endpoint_json(st, args.label), indent=2),
        "ai-commits-stats.json": json.dumps(st, indent=2),
        "ai-commits-card.svg": card_svg(st, args.name),
    }
    if args.themes:
        for theme in ("light", "dark"):
            files[f"ai-commits-card-{theme}.svg"] = card_svg(st, args.name, theme)
    for filename, content in files.items():
        (out / filename).write_bytes((content + "\n").encode("utf-8"))
    if args.github_output:
        with Path(args.github_output).open("a", encoding="utf-8", newline="\n") as output:
            for key in ("ai_percent", "commits", "ai_commits", "agent", "coauthored", "unattributed", "excluded_automation"):
                value = "n/a" if st[key] is None else st[key]
                output.write(f"{key.replace('_', '-')}={value}\n")
    print(json.dumps(st, indent=2))


if __name__ == "__main__":
    main()
