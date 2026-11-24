#!/usr/bin/env python3
"""Print the digest of one artifact in a release index.

Usage: atcd-index-digest.py <index.json> <package> <target>

Prints artifacts[<package>][<target>]["digest"] of the index, for example
"sha256:<64 hex>". The value comes from that JSON path, as atcd reads it. A
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
import json
import math
import re
import sys

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


def digest(raw, package, target):
    if raw.startswith(b"\xef\xbb\xbf"):
        raise ValueError("the index starts with a BOM")
    doc = json.loads(
        raw.decode("utf-8"),
        object_pairs_hook=no_duplicates,
        parse_constant=no_constant,
        parse_float=finite_float,
    )
    check_tree(doc)
    value = doc["artifacts"][package][target]["digest"]
    if not isinstance(value, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", value):
        raise ValueError("the digest is not sha256:<64 hex>")
    return value


def main(argv):
    if len(argv) != 4:
        print("usage: atcd-index-digest.py <index.json> <package> <target>", file=sys.stderr)
        return 2
    try:
        with open(argv[1], "rb") as f:
            print(digest(f.read(), argv[2], argv[3]))
    except (OSError, ValueError, KeyError, TypeError, RecursionError) as e:
        print("atcd-index-digest: %s: %s %s: %r" % (argv[1], argv[2], argv[3], e), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
