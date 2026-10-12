#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
find Sources Tests Examples Integrations Tools -name '*.swift' -not -path '*/.build/*' -not -path '*/Generated/*' -print0 |
    xargs -0 swift format lint --strict
swift format lint --strict Package.swift
