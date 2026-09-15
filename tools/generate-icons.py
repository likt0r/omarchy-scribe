#!/usr/bin/env python3
"""Regenerate icons.json from a Nerd Font.

The glyph names come out of the font's own `post` table -- `md-pencil`,
`fa-scissors`, `oct-repo` -- which is what makes the picker searchable without
shipping a name list from anywhere else. Run this when the font gains glyphs:

    python3 tools/generate-icons.py            # uses the resolved monospace font
    python3 tools/generate-icons.py FONT.ttf

Needs fontTools, which is a build-time dependency only: the plugin itself
reads the generated JSON and never opens a font file.
"""

import json
import os
import subprocess
import sys

PLUGIN_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))

# Everything from the Private Use Area up is a Nerd Font addition; below it
# lives the ordinary text the font is actually for.
FIRST_CODEPOINT = 0xE000


def default_font():
    out = subprocess.run(["fc-match", "-f", "%{file}", "monospace"],
                         capture_output=True, text=True, timeout=10)
    return out.stdout.strip()


def main(argv):
    from fontTools.ttLib import TTFont

    path = argv[1] if len(argv) > 1 else default_font()
    if not path or not os.path.exists(path):
        print("No font at %r" % path, file=sys.stderr)
        return 1

    font = TTFont(path, lazy=True)
    icons = []
    for codepoint, name in sorted(font.getBestCmap().items()):
        if codepoint < FIRST_CODEPOINT:
            continue
        # A glyph the font names only after its own codepoint cannot be
        # searched for, and an icon nobody can find is noise in the grid.
        if name.lower().lstrip("u").lstrip("ni").startswith(("%04x" % codepoint, "%05x" % codepoint)):
            continue
        icons.append([chr(codepoint), name])

    target = os.path.join(PLUGIN_DIR, "icons.json")
    with open(target, "w", encoding="utf-8") as handle:
        json.dump({"icons": icons}, handle, ensure_ascii=False, separators=(",", ":"))
        handle.write("\n")

    print("%d icons from %s -> %s (%.0f KB)"
          % (len(icons), os.path.basename(path), os.path.basename(target),
             os.path.getsize(target) / 1024))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
