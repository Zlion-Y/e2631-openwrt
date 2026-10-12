#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dts_lint.py - static checks for a board .dts that sits on top of a .dtsi.

There is no dtc and no cpp on this machine, so the only way to catch the
mistakes that would stop a CI build before spending a build slot is to
reproduce the part of dtc's job that does not need a real parser:

  1. /dts-v1/ directive - required by the top-level .dts, and NOT provided by a
                          .dtsi, so a board file that only includes .dtsi files
                          has to carry it itself;
  2. every #include     - the quoted form has to resolve, relative to the file
                          that wrote it, to a file that exists in the tree;
  3. every &label       - has to be defined in the board file or in anything it
                          includes (labels are collected from C-preprocessed
                          text, comments stripped first so that an example
                          written inside a /* */ block is not treated as one);
  4. &{/absolute/path}  - reported if it is not absolute.

Usage:
  dts_lint.py BOARD.dts [--root DIR] [--extra FILE ...] [--extract-to PATH]

  --root       include search root (default: the board file's directory).
               Point it at a staging dir that has zte/zx279128s.dtsi in it.
  --extra      an extra file to read labels from. A unified diff is understood
               and the file it adds is used (that is how the dtsi is read
               straight out of target patch 025 without applying it).
  --extract-to if an --extra is a patch, write the added file here first.

Exit code is 1 if any ERROR was found, so it can gate a commit.
"""

import argparse
import os
import re
import sys

RE_LABEL_DEF = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?=[A-Za-z_&{])", re.M)
RE_REF = re.compile(r"(?<!&)&(?:\{([^}]*)\}|([A-Za-z_][A-Za-z0-9_]*))")
RE_INC_ANGLE = re.compile(r'^\s*#include\s*<([^>]+)>', re.M)
RE_INC_QUOTE = re.compile(r'^\s*#include\s*"([^"]+)"', re.M)

# Symbols a board file normally gets from the kernel's dt-bindings headers.
# Listed so a value built from one (GIC_SPI, GPIO_ACTIVE_LOW, ...) is not
# reported as an unresolved label. The check is "did you mean a label", not
# "is this symbol defined".
KNOWN_CPP = {
    "GIC_SPI", "GIC_PPI", "GIC_CPU_MASK_SIMPLE",
    "IRQ_TYPE_NONE", "IRQ_TYPE_EDGE_RISING", "IRQ_TYPE_EDGE_FALLING",
    "IRQ_TYPE_LEVEL_HIGH", "IRQ_TYPE_LEVEL_LOW",
    "GPIO_ACTIVE_HIGH", "GPIO_ACTIVE_LOW", "GPIO_OPEN_DRAIN",
    "GPIO_PULL_UP", "GPIO_PULL_DOWN",
    "LED_FUNCTION_POWER", "LED_FUNCTION_WAN", "LED_FUNCTION_USB",
    "LED_FUNCTION_WLAN", "LED_FUNCTION_WLAN_2GHZ", "LED_FUNCTION_WLAN_5GHZ",
    "LED_FUNCTION_WPS", "LED_FUNCTION_WAN_ONLINE", "LED_FUNCTION_STATUS",
    "LED_COLOR_ID_RED", "LED_COLOR_ID_GREEN", "LED_COLOR_ID_BLUE",
    "LED_COLOR_ID_WHITE", "LED_COLOR_ID_AMBER",
    "KEY_RESTART", "KEY_WPS_BUTTON", "KEY_RFKILL", "KEY_LIGHTS_TOGGLE",
    "KEY_POWER", "KEY_RESET",
}


def strip_comments(text):
    """Blank out /* */ and // comments, keeping the line numbering intact.

    Newlines inside a removed comment are preserved so a later "line N" is the
    line the reader sees in an editor.
    """
    def blank_block(m):
        return "\n" * m.group(0).count("\n")
    text = re.sub(r"/\*.*?\*/", blank_block, text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def strip_patch(text, want=None):
    """Return the body of the file a unified diff adds (the '+' lines).

    A patch may add several files; `want` picks the one whose '+++ b/...' path
    contains that substring. Without `want` the first added file is returned.
    """
    out, started = [], False
    for line in text.splitlines():
        if line.startswith("+++ "):
            target = line[4:].strip()
            if started:
                break                       # already collected a file; new one starts
            if want is not None and want not in target:
                started = False
                continue
            started = True
            continue
        if not started:
            continue
        if line.startswith("@@"):
            continue
        if line.startswith("+"):
            out.append(line[1:])
        elif line.startswith("diff --git") or line.startswith("-- "):
            break
    return "\n".join(out) + "\n"


def load(path, extract_patch=False, want=None):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        raw = fh.read()
    if extract_patch or (raw.startswith("From ") and "\n+++ " in raw):
        return strip_patch(raw, want)
    return raw


def collect_labels(texts):
    labels = set()
    for _name, text in texts:
        for m in RE_LABEL_DEF.finditer(strip_comments(text)):
            labels.add(m.group(1))
    return labels


def collect_refs(text):
    body = strip_comments(text)
    refs = []
    for m in RE_REF.finditer(body):
        path_or_name, name = m.group(1), m.group(2)
        line = body.count("\n", 0, m.start()) + 1
        if path_or_name is not None:
            refs.append(("path", path_or_name.strip(), line))
        elif name not in KNOWN_CPP:
            refs.append(("label", name, line))
    return refs


def included_labels(dts_path, text, root, visited):
    """Walk quoted includes and return [(rel, text)] plus missing ones."""
    found, missing = [], []
    for rel in RE_INC_QUOTE.findall(text):
        p = os.path.normpath(os.path.join(root, rel))
        if not os.path.isfile(p):
            # second chance: relative to the including file's own directory
            p2 = os.path.normpath(os.path.join(os.path.dirname(dts_path), rel))
            if os.path.isfile(p2):
                p = p2
            else:
                missing.append((rel, p))
                continue
        if p in visited:
            continue
        visited.add(p)
        body = load(p)
        found.append((rel, body))
        sub_ok, sub_missing, _ = included_labels(p, body, os.path.dirname(p), visited)
        found.extend(sub_ok)
        missing.extend(sub_missing)
    return found, missing, visited


def has_dts_v1(dts_path, text, visited, root=None):
    if re.search(r"^\s*/dts-v1/\s*;", strip_comments(text), re.M):
        return True
    for rel in RE_INC_QUOTE.findall(strip_comments(text)):
        # same two places included_labels() looks: the root, then the dir of
        # the file that wrote the #include
        for base in filter(None, (root, os.path.dirname(dts_path))):
            p = os.path.normpath(os.path.join(base, rel))
            if os.path.isfile(p) and p not in visited:
                visited.add(p)
                if has_dts_v1(p, load(p), visited, root):
                    return True
    return False


def lint(dts, root, extras):
    text = load(dts)
    errors, warns = [], []

    if not has_dts_v1(dts, text, set(), root):
        errors.append("no /dts-v1/; directive, in this file or in any quoted "
                      "include. dtc requires it and a .dtsi never supplies it.")

    incs, missing, _ = included_labels(dts, text, root, set())
    if missing:
        # Without this, an unresolvable include turns into one "unresolved
        # label" per &reference, which reads like the board file is broken.
        warns.append("hint: a quoted include did not resolve (%s). If that is "
                     "the SoC dtsi, this run never saw the labels it defines, "
                     "so every &label below will look undefined. Pass --root "
                     "DIR where DIR/ holds the include path, e.g. --root "
                     "<tree>/arch/arm/boot/dts."
                     % ", ".join(rel for rel, _ in missing))
    for rel, p in missing:
        errors.append('quoted include "%s" not found (looked at %s)' % (rel, p))

    for hdr in RE_INC_ANGLE.findall(strip_comments(text)):
        if not hdr.startswith("dt-bindings/"):
            warns.append("#include <%s> is not under dt-bindings/" % hdr)

    labels = collect_labels([(dts, text)] + incs + extras)

    for kind, name, line in collect_refs(text):
        if kind == "label":
            if name not in labels:
                errors.append("unresolved label &%s (line %d)" % (name, line))
        elif not name.startswith("/"):
            warns.append("&{%s} (line %d) is not an absolute path" % (name, line))

    return errors, warns, len(labels)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dts", nargs="+")
    ap.add_argument("--root", default=None)
    ap.add_argument("--extra", action="append", default=[])
    ap.add_argument("--extract-to", default=None)
    ap.add_argument("--extract-name", default=None,
                    help="with --extract-to, pick the patch's file whose path "
                         "contains this substring")
    args = ap.parse_args()

    if args.extract_to and args.extra:
        body = load(args.extra[0], extract_patch=True, want=args.extract_name)
        os.makedirs(os.path.dirname(os.path.abspath(args.extract_to)), exist_ok=True)
        with open(args.extract_to, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(body)
        print("extracted %s -> %s (%d bytes)"
              % (args.extra[0], args.extract_to, len(body)))

    extras = [(os.path.basename(e), load(e, extract_patch=True)) for e in args.extra]

    rc = 0
    for dts in args.dts:
        root = args.root or os.path.dirname(os.path.abspath(dts))
        print("=" * 78)
        print("lint %s" % dts)
        print("     include root: %s" % root)
        print("=" * 78)
        errors, warns, nlabels = lint(dts, root, extras)
        print("  labels visible: %d" % nlabels)
        for w in warns:
            print("  WARN  %s" % w)
        if errors:
            rc = 1
            for e in errors:
                print("  ERROR %s" % e)
        else:
            print("  no reference errors")
        print("  -> %s" % ("FAIL" if errors else "PASS"))
    return rc


if __name__ == "__main__":
    sys.exit(main())
