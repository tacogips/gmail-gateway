#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
products=(
  "mail-gateway-reader"
  "mail-gateway-draft"
  "mail-gateway-sender"
)

usage() {
  cat <<EOF
Usage:
  scripts/render-homebrew-formula.sh <version> [product ...] [output-dir]

Products:
  mail-gateway-reader  mail-gateway-draft  mail-gateway-sender

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

is_product() {
  local candidate product
  candidate="$1"
  for product in "${products[@]}"; do
    if [[ "$candidate" == "$product" ]]; then
      return 0
    fi
  done
  return 1
}

formula_class() {
  case "$1" in
    mail-gateway-reader) printf '%s\n' "MailGatewayReader" ;;
    mail-gateway-draft) printf '%s\n' "MailGatewayDraft" ;;
    mail-gateway-sender) printf '%s\n' "MailGatewaySender" ;;
    *)
      printf 'unsupported Homebrew product: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

formula_desc() {
  case "$1" in
    mail-gateway-reader) printf '%s\n' "Read-only Gmail workflow gateway" ;;
    mail-gateway-draft) printf '%s\n' "Draft-writing Gmail workflow gateway" ;;
    mail-gateway-sender) printf '%s\n' "Direct-send Gmail workflow gateway" ;;
    *)
      printf 'unsupported Homebrew product: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

sha_for_target() {
  local product version target release_dir sha_file
  product="$1"
  version="$2"
  target="$3"
  release_dir="$4"
  sha_file="$release_dir/$product-$version-$target.tar.gz.sha256"

  if [[ ! -f "$sha_file" ]]; then
    printf 'missing checksum file: %s\n' "$sha_file" >&2
    return 1
  fi

  awk '{print $1}' "$sha_file"
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
  class="$(formula_class "$product")"
  desc="$(formula_desc "$product")"
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

  local -a selected_products
  selected_products=()

  local arg
  for arg in "$@"; do
    if is_product "$arg"; then
      selected_products+=("$arg")
    else
      output_dir="$arg"
    fi
  done

  if [[ "${#selected_products[@]}" -eq 0 ]]; then
    selected_products=("${products[@]}")
  fi

  local product
  for product in "${selected_products[@]}"; do
    render_formula "$product" "$version" "$output_dir" "$release_dir" "$release_base_url"
  done
}

main "$@"
