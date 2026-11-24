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
value, as atcd does.
"""
import json
import re
import sys


def no_duplicates(pairs):
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError("duplicate key in an object")
    return dict(pairs)


def digest(raw, package, target):
    doc = json.loads(raw, object_pairs_hook=no_duplicates)
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
    except (OSError, ValueError, KeyError, TypeError) as e:
        print("atcd-index-digest: %s: %s %s: %r" % (argv[1], argv[2], argv[3], e), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
