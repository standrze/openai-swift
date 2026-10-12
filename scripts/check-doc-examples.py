#!/usr/bin/env python3
"""Type-check complete public Swift examples against a built OpenAI module."""

import argparse
from pathlib import Path
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("module_path", type=Path, help="directory containing OpenAI.swiftmodule")
    parser.add_argument("--module-cache", default="/tmp/openai-docs-module-cache")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    documents = [
        root / "README.md",
        root / "Documentation/Architecture.md",
        root / "Documentation/Protocols.md",
        root / "Documentation/GeneratedAPI.md",
        root / "Documentation/Helpers.md",
    ]
    checked = 0
    fragments = 0
    with tempfile.TemporaryDirectory(prefix="openai-docs-") as temporary:
        for document in documents:
            for index, snippet in enumerate(re.findall(r"```swift\n(.*?)```", document.read_text(), re.S), 1):
                if not snippet.lstrip().startswith("import "):
                    fragments += 1
                    continue
                path = Path(temporary) / (document.stem + "-" + str(index) + ".swift")
                path.write_text(snippet)
                subprocess.run([
                    "swiftc", "-typecheck", "-swift-version", "6",
                    "-I", str(args.module_path.resolve()), "-module-cache-path", args.module_cache, str(path),
                ], check=True)
                checked += 1
    print("Type-checked %d complete Swift examples; %d package-manifest fragments excluded" % (checked, fragments))


if __name__ == "__main__":
    main()
