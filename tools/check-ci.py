#!/usr/bin/env python3
"""Static checks for .github/workflows/build-initramfs.yml.

The workflow is the only way this port is ever built -- an OpenWrt build needs
Linux and about 25 GB and the machine it was written on has neither -- and for
a long time it had never been run, which is how it came to ask apt for
python3-distutils, a package that does not exist in Ubuntu 24.04. That would
have failed the job in seconds, on the first push, with an error about apt
rather than about the port.

So this runs on the workflow file what tools/dts_lint.py runs on the device
tree: the checks that need no network and no runner, and that catch a mistake
before it costs a build. Two things it cannot do, and does not pretend to:
it does not run the workflow, and it does not know whether a package exists --
for that pass --apt, which asks Launchpad.

    tools/check-ci.py                 # offline checks
    tools/check-ci.py --apt           # also check every apt package exists

Only the standard library is used, like dts_lint.py, so it runs anywhere the
rest of this repo does. Exit status is 1 if anything failed.
"""

import argparse
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "build-initramfs.yml")
FRAGMENT = os.path.join(ROOT, "fragments", "device-e2631.mk")

# Packages that are named in the workflow but are not installable on the
# runner's distribution. Kept as a table rather than a rule because each one
# is a specific, explained fact -- and because a rule would need the network.
NOT_IN_NOBLE = {
    "python3-distutils":
        "removed with Python 3.12; not in Ubuntu 24.04 at all "
        "(packages.ubuntu.com/noble/python3-distutils is an error page and "
        "Launchpad's noble/amd64 binary index returns nothing)",
}

# The target's image/Makefile sets DEVICE_VENDOR := ZTE in Device/Default and
# this repo does not override it, so the vendor is not in this repo to read.
# If that ever changes, this constant and the workflow comment change with it.
VENDOR = "ZTE"

DEB_SERIES = "https://api.launchpad.net/1.0/ubuntu/noble/amd64"


def image_name(vendor, model):
    """OpenWrt's artefact name: vendor + '_' + model, lowercased, spaces to
    hyphens. ZTE + 'ZXHN E2631' -> zte_zxhn-e2631, which is what the workflow
    asserts; the same rule gives zte_zxhn-h3600 for the H3600 and
    xiaomi_redmi-router-ac2100 for the AC2100."""
    return (vendor + "_" + model).lower().replace(" ", "-")


def apt_packages(text):
    """Package names from every `apt-get install` block, following the
    backslash continuations. Flags are dropped."""
    pkgs = []
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if "apt-get install" not in line:
            continue
        chunk = [line]
        j = i
        while lines[j].rstrip().endswith("\\") and j + 1 < len(lines):
            j += 1
            chunk.append(lines[j])
        joined = " ".join(chunk)
        joined = joined.split("apt-get install", 1)[1].replace("\\", " ")
        for tok in joined.split():
            if tok.startswith("-"):
                continue
            pkgs.append(tok)
    return sorted(set(pkgs))


def launchpad_has(pkg):
    q = urllib.parse.urlencode({
        "binary_name": pkg,
        "exact_match": "true",
        "status": "Published",
        "distro_arch_series": DEB_SERIES,
    })
    url = "https://api.launchpad.net/1.0/ubuntu/+archive/primary?" \
          "ws.op=getPublishedBinaries&" + q
    req = urllib.request.Request(url, headers={"User-Agent": "e2631-check-ci"})
    body = urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "replace")
    m = re.search(r'"total_size":\s*(\d+)', body)
    return (int(m.group(1)) > 0) if m else None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apt", action="store_true",
                    help="also query Launchpad: does each apt package exist in noble")
    args = ap.parse_args()

    errors = []
    notes = []

    if not os.path.isfile(WORKFLOW):
        sys.exit("error: %s not found" % WORKFLOW)
    text = open(WORKFLOW, encoding="utf-8").read()
    frag = open(FRAGMENT, encoding="utf-8").read() if os.path.isfile(FRAGMENT) else ""

    # --- the artefact name the workflow asserts must be the one the build
    # --- will produce, and that follows from the device model in the fragment
    m = re.search(r"^\s*DEVICE_MODEL\s*:=\s*(.+?)\s*$", frag, re.M)
    if not m:
        errors.append("fragments/device-e2631.mk has no DEVICE_MODEL, so the "
                      "artefact name the workflow asserts cannot be derived")
        expected = None
    else:
        expected = image_name(VENDOR, m.group(1))
        want = "-%s-initramfs.uImage" % expected
        if want not in text:
            errors.append("the workflow never names %s, which is what "
                          "DEVICE_MODEL '%s' produces" % (want, m.group(1)))
        if not re.search(r"test -f\s+\S*%s" % re.escape(expected), text):
            errors.append("the workflow does not assert the build produced "
                          "%s -- without it the job goes green with no image"
                          % expected)

    # --- files the workflow invokes have to be in the repo
    for name in ("apply.sh", "check-dts.sh", "seed/e2631.config",
                 "fragments/device-e2631.mk"):
        if name in text and not os.path.exists(os.path.join(ROOT, name)):
            errors.append("the workflow uses %s but it is not in the repo" % name)

    # --- apt
    pkgs = apt_packages(text)
    if not pkgs:
        errors.append("no apt packages found -- the install block changed shape "
                      "and this check is no longer looking at it")
    for p in pkgs:
        if p in NOT_IN_NOBLE:
            errors.append("apt package %s cannot be installed: %s" % (p, NOT_IN_NOBLE[p]))
    if "device-tree-compiler" not in pkgs:
        errors.append("device-tree-compiler is gone from the apt list; both "
                      "check-dts.sh and the image build need dtc")
    if args.apt:
        for p in pkgs:
            try:
                ok = launchpad_has(p)
            except (urllib.error.URLError, OSError) as e:
                notes.append("could not check %s: %s" % (p, e))
                continue
            if ok is False:
                errors.append("apt package %s is not published for noble/amd64" % p)
            elif ok is None:
                notes.append("no answer from Launchpad for %s" % p)
        notes.append("--apt queried Launchpad for %d package(s)" % len(pkgs))

    # --- things that must not come back. Matched as an assignment, not as a
    # --- word: the comment above the Build step names IGNORE_ERRORS on purpose
    # --- to explain why it is not used, and a plain substring search flags it.
    if re.search(r"IGNORE_ERRORS\s*=", text):
        errors.append("IGNORE_ERRORS is back. At stage 1 the first failure is "
                      "the deliverable; ignoring errors turns a real breakage "
                      "into a missing artefact an hour later")

    # --- the release step needs a writable token; new repos default to read-only
    if "action-gh-release" in text and not re.search(r"contents:\s*write", text):
        errors.append("an action-gh-release step is present without "
                      "'permissions: contents: write'; GITHUB_TOKEN defaults "
                      "to read-only on new repositories and it would 403")

    # --- actions pinned to a major tag, not to a branch
    for ref in re.findall(r"uses:\s*(\S+)", text):
        if "@" not in ref:
            errors.append("action %s has no version pin" % ref)
            continue
        ver = ref.rsplit("@", 1)[1]
        if not re.match(r"^v?\d", ver):
            errors.append("action %s is pinned to '%s', which is not a version"
                          % (ref, ver))

    # --- the job that builds must wait for the fast device tree check
    if re.search(r"^\s*build:", text, re.M) and "needs: dts" not in text:
        notes.append("the build job no longer waits for the dts job")

    if notes:
        for n in notes:
            print("note: %s" % n)
    if errors:
        for e in errors:
            print("FAIL: %s" % e)
        print("\n%d problem(s) in %s" % (len(errors), os.path.relpath(WORKFLOW, ROOT)))
        return 1
    print("PASS: %s" % os.path.relpath(WORKFLOW, ROOT))
    if expected:
        print("      artefact asserted: %s" % expected)
    print("      %d apt package(s) named" % len(pkgs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
