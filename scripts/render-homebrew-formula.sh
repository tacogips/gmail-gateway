#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
source "$script_dir/homebrew-release-common.sh"

usage() {
  cat <<EOF
Usage:
  scripts/render-homebrew-formula.sh <version> [product ...] [output-dir]

Products:
  $(homebrew_product_list)

Reads archive checksums from:
  dist/homebrew/<product>-<version>-<target>.tar.gz.sha256

Environment:
  RELEASE_DIR       Directory containing archives and .sha256 files.
  RELEASE_BASE_URL  Release URL base. Defaults to GitHub v<version>.

Examples:
  scripts/build-homebrew-release.sh darwin-arm64 darwin-x64
  scripts/render-homebrew-formula.sh 0.1.2 ../homebrew-tap/Formula
  scripts/render-homebrew-formula.sh 0.1.2 mail-gateway-reader ../homebrew-tap/Formula

This renderer expects Swift macOS release archives. Linux archives are
unsupported until the project defines a reviewed Swift Linux build contract.
EOF
}

validate_release_base_url() {
  local value url_pattern
  value="$1"
  url_pattern='^https://[0-9A-Za-z._~:/?@!$%&()*+,;=-]+$'

  if [[ ! "$value" =~ $url_pattern ]]; then
    printf 'unsafe release base URL: %s\n' "$value" >&2
    printf 'expected https URL using archive-safe characters only\n' >&2
    return 1
  fi
}

sha_for_target() {
  local product version target release_dir sha_file sha
  product="$1"
  version="$2"
  target="$3"
  release_dir="$4"
  sha_file="$release_dir/$product-$version-$target.tar.gz.sha256"

  if [[ ! -f "$sha_file" ]]; then
    printf 'missing checksum file: %s\n' "$sha_file" >&2
    return 1
  fi

  sha="$(awk 'NR == 1 { print $1 }' "$sha_file")"
  if [[ ! "$sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
    printf 'invalid sha256 in %s: %s\n' "$sha_file" "$sha" >&2
    return 1
  fi
  printf '%s\n' "$sha"
}

render_formula() {
  local product version output_dir release_dir release_base_url
  product="$1"
  version="$2"
  output_dir="$3"
  release_dir="$4"
  release_base_url="$5"

  local darwin_arm64_sha darwin_x64_sha class desc output
  darwin_arm64_sha="$(sha_for_target "$product" "$version" darwin-arm64 "$release_dir")"
  darwin_x64_sha="$(sha_for_target "$product" "$version" darwin-x64 "$release_dir")"
  class="$(homebrew_formula_class "$product")"
  desc="$(homebrew_formula_desc "$product")"
  output="$output_dir/$product.rb"

  mkdir -p "$(dirname "$output")"
  cat > "$output" <<EOF
class $class < Formula
  desc "$desc"
  homepage "https://github.com/tacogips/mail-gateway"
  version "$version"
  license "MIT"

  livecheck do
    url :stable
    strategy :github_latest
  end

  on_macos do
    if Hardware::CPU.arm?
      url "$release_base_url/$product-$version-darwin-arm64.tar.gz"
      sha256 "$darwin_arm64_sha"
    else
      url "$release_base_url/$product-$version-darwin-x64.tar.gz"
      sha256 "$darwin_x64_sha"
    end
  end

  def install
    bin.install "bin/$product"
  end

  test do
    assert_match "Usage:", shell_output("#{bin}/$product --help")
  end
end
EOF

  printf 'rendered %s\n' "$output"
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    return
  fi
  if [[ "${1:-}" == "" ]]; then
    usage
    return 2
  fi

  local version output_dir release_dir release_base_url
  version="$1"
  shift
  output_dir="$repo_root/Formula"
  release_dir="${RELEASE_DIR:-$repo_root/dist/homebrew}"
  release_base_url="${RELEASE_BASE_URL:-https://github.com/tacogips/mail-gateway/releases/download/v$version}"
  validate_homebrew_version "$version"
  validate_release_base_url "$release_base_url"

  local -a selected_products
  selected_products=()

  local arg output_dir_set
  output_dir_set=false
  for arg in "$@"; do
    if is_homebrew_product "$arg"; then
      if [[ "$output_dir_set" == true ]]; then
        printf 'product arguments must come before the output directory: %s\n' "$arg" >&2
        usage >&2
        return 2
      fi
      selected_products+=("$arg")
    else
      if [[ "$arg" == mail-gateway-* ]]; then
        printf 'unsupported Homebrew product: %s\n' "$arg" >&2
        printf 'supported products: %s\n' "$(homebrew_product_list)" >&2
        return 2
      fi
      if [[ "$output_dir_set" == true ]]; then
        printf 'multiple output directories were provided: %s\n' "$arg" >&2
        usage >&2
        return 2
      fi
      output_dir="$arg"
      output_dir_set=true
    fi
  done

  if [[ "${#selected_products[@]}" -eq 0 ]]; then
    selected_products=("${homebrew_products[@]}")
  fi

  local product
  for product in "${selected_products[@]}"; do
    render_formula "$product" "$version" "$output_dir" "$release_dir" "$release_base_url"
  done
}

main "$@"
