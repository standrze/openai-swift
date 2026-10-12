#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Generated files are byte-for-byte Apple generator output, verified by regenerate-api.rb --check.
find Sources Tests Examples Integrations Tools -name '*.swift' -not -path '*/.build/*' -not -path '*/Generated/*' -print0 |
    xargs -0 swift format format --in-place
swift format format --in-place Package.swift
