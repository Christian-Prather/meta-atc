#!/usr/bin/env python3
"""Print the digest of one artifact in a release index.

Usage: atcd-index-digest.py <index.json> <package> <target>
       atcd-index-digest.py <index.json> <package> <target> \
           --extract <tar> <dir> <member>...

Prints artifacts[<package>][<target>]["digest"] of the index, for example
"sha256:<64 hex>".

With --extract, it also copies each named member of the plain tar file into
<dir>, under the base name of the member. Each member must be a regular file,
and only one in the tar. Its sha256 and size must equal the one entry for its
path in the "manifest" list of the same index entry. A symbolic link, a hard
link or a device with that name is refused. Members with other names are not
read. The value comes from that JSON path, as atcd reads it. A
text search is not enough: a nested object can hold the same text as the
entry, so a search could find text that atcd never reads.

Exits 1, with the reason on stderr, when the file is not one JSON object,
when an object has a duplicate key, or when the path or a sha256 digest is
not there. atcd keeps the last of two equal keys, so this script refuses
them. Python's json module decodes escapes and refuses bytes after the root
value, as atcd does. It also refuses the bytes that atcd (serde_json)
refuses and Python takes: bytes that are not UTF-8 or that start with a BOM,
NaN and Infinity, a number too large for a float, a lone surrogate, and
nesting deeper than 128.
"""
import hashlib
import json
import math
import os
import re
import sys
import tarfile

MAX_DEPTH = 128  # serde_json's default recursion limit


def no_duplicates(pairs):
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError("duplicate key in an object")
    return dict(pairs)


def no_constant(name):
    raise ValueError("%s is not JSON" % name)


def finite_float(text):
    value = float(text)
    if not math.isfinite(value):
        raise ValueError("the number %s is out of range" % text)
    return value


def check_tree(value, depth=1):
    if depth > MAX_DEPTH:
        raise ValueError("nesting deeper than %d" % MAX_DEPTH)
    if isinstance(value, dict):
        items = list(value.keys()) + list(value.values())
    elif isinstance(value, list):
        items = value
    else:
        items = []
    for item in items:
        if isinstance(item, str):
            # A lone surrogate is not UTF-8 text.
            item.encode("utf-8")
        else:
            check_tree(item, depth + 1)


def entry(raw, package, target):
    if raw.startswith(b"\xef\xbb\xbf"):
        raise ValueError("the index starts with a BOM")
    doc = json.loads(
        raw.decode("utf-8"),
        object_pairs_hook=no_duplicates,
        parse_constant=no_constant,
        parse_float=finite_float,
    )
    check_tree(doc)
    found = doc["artifacts"][package][target]
    value = found["digest"]
    if not isinstance(value, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", value):
        raise ValueError("the digest is not sha256:<64 hex>")
    return found


def manifest_file(found, path):
    """Return (sha256, size) of the one manifest entry for path."""
    manifest = found["manifest"]
    if not isinstance(manifest, list):
        raise ValueError("the manifest is not a list")
    hits = [m for m in manifest if isinstance(m, dict) and m.get("path") == path]
    if len(hits) != 1:
        raise ValueError("the manifest has %d entries for %s, not 1" % (len(hits), path))
    m = hits[0]
    if m.get("type") != "file":
        raise ValueError("the manifest entry for %s is not a file" % path)
    sha, size = m.get("sha256"), m.get("size")
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
        raise ValueError("the manifest sha256 of %s is not 64 hex" % path)
    if type(size) is not int or size < 0:
        raise ValueError("the manifest size of %s is not a count of bytes" % path)
    return sha, size


def extract(found, tar_path, out_dir, members):
    """Write the members into out_dir, or write nothing and raise."""
    want = {m: manifest_file(found, m) for m in members}
    if len({os.path.basename(m) for m in members}) != len(members):
        raise ValueError("two members have the same base name")
    staged = {}
    try:
        # "r:" reads a plain tar only. Compression is the caller's step.
        with tarfile.open(tar_path, mode="r:") as tar:
            for info in tar:
                if info.name not in want:
                    continue
                if info.name in staged:
                    raise ValueError("the tar holds %s more than once" % info.name)
                if not info.isreg():
                    raise ValueError("%s in the tar is not a regular file" % info.name)
                sha, size = want[info.name]
                tmp = os.path.join(out_dir, "." + os.path.basename(info.name) + ".tmp")
                staged[info.name] = tmp
                h = hashlib.sha256()
                got = 0
                src = tar.extractfile(info)
                with open(tmp, "wb") as out:
                    for chunk in iter(lambda: src.read(1 << 16), b""):
                        h.update(chunk)
                        got += len(chunk)
                        out.write(chunk)
                if got != size or h.hexdigest() != sha:
                    raise ValueError(
                        "%s has sha256 %s and size %d, but the signed manifest says %s and %d"
                        % (info.name, h.hexdigest(), got, sha, size)
                    )
        missing = sorted(set(want) - set(staged))
        if missing:
            raise ValueError("the tar has no %s" % ", ".join(missing))
    except BaseException:
        for tmp in staged.values():
            try:
                os.unlink(tmp)
            except FileNotFoundError:
                pass
        raise
    for name, tmp in staged.items():
        os.replace(tmp, os.path.join(out_dir, os.path.basename(name)))


def digest(raw, package, target):
    return entry(raw, package, target)["digest"]


def main(argv):
    extract_args = None
    if len(argv) > 4 and argv[4] == "--extract" and len(argv) >= 8:
        extract_args = argv[5:]
    elif len(argv) != 4:
        print("usage: atcd-index-digest.py <index.json> <package> <target> "
              "[--extract <tar> <dir> <member>...]", file=sys.stderr)
        return 2
    try:
        with open(argv[1], "rb") as f:
            found = entry(f.read(), argv[2], argv[3])
        if extract_args:
            extract(found, extract_args[0], extract_args[1], extract_args[2:])
        print(found["digest"])
    except (OSError, ValueError, KeyError, TypeError, RecursionError, tarfile.TarError) as e:
        print("atcd-index-digest: %s: %s %s: %r" % (argv[1], argv[2], argv[3], e), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
