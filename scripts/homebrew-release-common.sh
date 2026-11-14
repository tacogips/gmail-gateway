homebrew_products=(
  "mail-gateway-reader"
  "mail-gateway-draft"
  "mail-gateway-sender"
)

homebrew_product_list() {
  local product separator
  separator=""
  for product in "${homebrew_products[@]}"; do
    printf '%s%s' "$separator" "$product"
    separator="  "
  done
  printf '\n'
}

is_homebrew_product() {
  local candidate product
  candidate="$1"
  for product in "${homebrew_products[@]}"; do
    if [[ "$candidate" == "$product" ]]; then
      return 0
    fi
  done
  return 1
}

validate_homebrew_product() {
  if ! is_homebrew_product "$1"; then
    printf 'unsupported Swift Homebrew product: %s\n' "$1" >&2
    printf 'supported products: %s\n' "$(homebrew_product_list)" >&2
    return 1
  fi
}

homebrew_formula_class() {
  case "$1" in
    mail-gateway-reader) printf '%s\n' "MailGatewayReader" ;;
    mail-gateway-draft) printf '%s\n' "MailGatewayDraft" ;;
    mail-gateway-sender) printf '%s\n' "MailGatewaySender" ;;
    *)
      validate_homebrew_product "$1"
      ;;
  esac
}

homebrew_formula_desc() {
  case "$1" in
    mail-gateway-reader) printf '%s\n' "Read-only Gmail workflow gateway" ;;
    mail-gateway-draft) printf '%s\n' "Draft-writing Gmail workflow gateway" ;;
    mail-gateway-sender) printf '%s\n' "Direct-send Gmail workflow gateway" ;;
    *)
      validate_homebrew_product "$1"
      ;;
  esac
}

validate_homebrew_version() {
  local version
  version="$1"

  if [[ "$version" == *..* || ! "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z][0-9A-Za-z.+-]*)?$ ]]; then
    printf 'unsafe release version: %s\n' "$version" >&2
    printf 'expected archive-safe semver-like value without path separators or parent traversal\n' >&2
    return 1
  fi
}
