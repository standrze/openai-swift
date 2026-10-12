#!/usr/bin/env python3
"""Compare the catalog reference against pinned official API.md source files, without network access."""

import argparse
import html
import json
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_dir", type=Path, help="directory containing openai-go-api.md and linked API files")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    reference = json.loads((root / "Documentation/Reference/openai-go-endpoints.json").read_text())
    expected = {(item["method"], item["path"], item["upstreamSymbol"]) for item in reference["operations"]}
    observed = set()
    for name in ["api"] + [group + "-api" for group in ["responses", "realtime", "conversations", "live", "webhooks"]]:
        path = args.source_dir / ("openai-go-" + name + ".md")
        text = path.read_text()
        for method, route, line in re.findall(r'<code title="(\w+) ([^"]+)">([^\n]+)', text):
            symbol = html.unescape(re.sub("<[^>]+>", "", line)).split("(")[0]
            observed.add((method.upper(), route.lstrip("/"), symbol))
    missing = observed - expected
    stale = expected - observed
    if missing or stale:
        raise SystemExit("Catalog mismatch: missing=%r stale=%r" % (sorted(missing), sorted(stale)))
    print("Verified %d named operations, %d distinct HTTP routes against pinned upstream sources" % (
        len(expected), len({(item[0], item[1]) for item in expected})))


if __name__ == "__main__":
    main()
