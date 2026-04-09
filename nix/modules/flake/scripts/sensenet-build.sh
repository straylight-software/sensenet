#!/usr/bin/env bash
# Build phase for sensenet builds
# Environment variables:
#   sensenet_target - build target (e.g., //src:myapp)

runHook preBuild

buck2 build "$sensenet_target" --show-full-output

runHook postBuild
