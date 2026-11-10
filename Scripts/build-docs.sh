#!/bin/bash
#
# Builds the DocC documentation for NetSkein's library modules with the
# Swift toolchain's own `docc`, so the package needs no docs plugin.
#
# Usage:
#   Scripts/build-docs.sh            Build every module's documentation.
#   Scripts/build-docs.sh --preview  Build NetSkein and serve it locally.
#
# Warnings, such as a link to a symbol that no longer exists, fail the
# build. Archives are written to .build/docs/archives.

set -euo pipefail

MODULES=("NetSkein" "NetSkeinTesting")

DOCS_DIR=".build/docs"
SCRATCH_DIR="${DOCS_DIR}/build"
MODULE_GRAPHS_DIR="${DOCS_DIR}/symbol-graphs"
ARCHIVE_DIR="${DOCS_DIR}/archives"

# `docc` ships with Swift: through xcrun on macOS, on the PATH on Linux.
if command -v xcrun > /dev/null 2>&1; then
  DOCC=(xcrun docc)
else
  DOCC=(docc)
fi

# Builds the package and writes symbol graphs for its own modules, then
# prints the directory they were written to. A separate scratch path
# keeps this build from touching the regular .build directory.
dump_symbol_graphs() {
  local output
  output="$(
    swift package --scratch-path "$SCRATCH_DIR" dump-symbol-graph \
      --minimum-access-level public \
      --emit-extension-block-symbols
  )"

  # The last line reads "Files written to <directory>".
  echo "$output" | sed -n 's/^Files written to //p'
}

# Copies one module's symbol graphs into their own directory, so DocC
# documents only that module. "Module@Other" files hold the module's
# extensions to other modules' types.
collect_module_graphs() {
  local graphs_dir="$1"
  local module="$2"
  local module_dir="${MODULE_GRAPHS_DIR}/${module}"

  rm -rf "$module_dir"
  mkdir -p "$module_dir"
  cp "${graphs_dir}/${module}.symbols.json" "$module_dir/"
  find "$graphs_dir" -maxdepth 1 -name "${module}@*.symbols.json" \
    -exec cp {} "$module_dir/" \;

  echo "$module_dir"
}

# Runs `docc convert` (or `docc preview`) for one module.
build_module_docs() {
  local command="$1"
  local graphs_dir="$2"
  local module="$3"
  local module_graphs
  module_graphs="$(collect_module_graphs "$graphs_dir" "$module")"

  mkdir -p "$ARCHIVE_DIR"
  "${DOCC[@]}" "$command" "Sources/${module}/${module}.docc" \
    --additional-symbol-graph-dir "$module_graphs" \
    --fallback-display-name "$module" \
    --fallback-bundle-identifier "com.orthogonest.${module}" \
    --output-path "${ARCHIVE_DIR}/${module}.doccarchive" \
    --warnings-as-errors
}

echo "Generating symbol graphs..."
GRAPHS_DIR="$(dump_symbol_graphs)"

if [ -z "$GRAPHS_DIR" ]; then
  echo "error: could not find the generated symbol graphs." >&2
  exit 1
fi

if [ "${1:-}" = "--preview" ]; then
  build_module_docs preview "$GRAPHS_DIR" "NetSkein"
  exit 0
fi

for module in "${MODULES[@]}"; do
  echo "Building documentation for ${module}..."
  build_module_docs convert "$GRAPHS_DIR" "$module"
done

echo "Documentation built in ${ARCHIVE_DIR}."
