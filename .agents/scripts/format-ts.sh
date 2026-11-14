#!/bin/bash
# Format TypeScript and Svelte files if they exist
shopt -s nullglob globstar
ts_files=(src/**/*.ts)
svelte_files=(client/**/*.svelte)
files=("${ts_files[@]}" "${svelte_files[@]}")
if [ ${#files[@]} -gt 0 ]; then
  bunx prettier --write "${files[@]}"
fi
exit 0
