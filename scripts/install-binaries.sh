#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_ROOT="${INSTALL_ROOT:-${ROOT_DIR}/.tools}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-${INSTALL_ROOT}/downloads}"
BIN_DIR="${BIN_DIR:-${INSTALL_ROOT}/bin}"

FABRIC_VERSION="${FABRIC_VERSION:-2.5.12}"
FABRIC_CA_VERSION="${FABRIC_CA_VERSION:-1.5.15}"

FORCE_DOWNLOAD=false
CHECK_ONLY=false

usage() {
  cat <<'EOF'
Usage:
  ./scripts/install-binaries.sh [--force] [--check]

Options:
  --force    Re-download archives even if they already exist
  --check    Only verify required local CLI binaries in .tools/bin
  -h, --help Show this help

Environment variables:
  FABRIC_VERSION      (default: 2.5.12)
  FABRIC_CA_VERSION   (default: 1.5.15)
  INSTALL_ROOT        (default: <repo>/.tools)
  DOWNLOAD_DIR        (default: <INSTALL_ROOT>/downloads)
  BIN_DIR             (default: <INSTALL_ROOT>/bin)
EOF
}

log() {
  echo "[install-binaries] $*"
}

require_binary() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' is not installed or not in PATH" >&2
    exit 1
  fi
}

detect_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"

  case "${os}" in
    linux|darwin) ;;
    *)
      echo "Error: unsupported OS '${os}'. Supported: linux, darwin" >&2
      exit 1
      ;;
  esac

  case "${arch}" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
      echo "Error: unsupported architecture '${arch}'. Supported: amd64, arm64" >&2
      exit 1
      ;;
  esac

  PLATFORM="${os}-${arch}"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force)
        FORCE_DOWNLOAD=true
        ;;
      --check)
        CHECK_ONLY=true
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Error: unknown option '$1'" >&2
        usage
        exit 1
        ;;
    esac
    shift
  done
}

verify_local_cli() {
  local missing=0
  local required=(peer configtxgen configtxlator osnadmin fabric-ca-client)

  for cmd in "${required[@]}"; do
    if [ ! -x "${BIN_DIR}/${cmd}" ]; then
      echo "Missing: ${BIN_DIR}/${cmd}" >&2
      missing=1
    fi
  done

  if [ "${missing}" -ne 0 ]; then
    return 1
  fi

  PATH="${BIN_DIR}:${PATH}" peer version >/dev/null
  PATH="${BIN_DIR}:${PATH}" configtxgen --version >/dev/null
  PATH="${BIN_DIR}:${PATH}" fabric-ca-client version >/dev/null
  PATH="${BIN_DIR}:${PATH}" osnadmin --help >/dev/null 2>&1

  return 0
}

download_archive() {
  local url="$1"
  local out="$2"

  if [ -f "${out}" ] && [ "${FORCE_DOWNLOAD}" = false ]; then
    log "Using cached archive: ${out}"
    return 0
  fi

  log "Downloading: ${url}"
  curl -fL "${url}" -o "${out}"
}

install_fabric_binaries() {
  local fabric_archive="${DOWNLOAD_DIR}/hyperledger-fabric-${PLATFORM}-${FABRIC_VERSION}.tar.gz"
  local fabric_url="https://github.com/hyperledger/fabric/releases/download/v${FABRIC_VERSION}/hyperledger-fabric-${PLATFORM}-${FABRIC_VERSION}.tar.gz"
  local tmpdir

  download_archive "${fabric_url}" "${fabric_archive}"

  tmpdir="$(mktemp -d)"
  tar -xzf "${fabric_archive}" -C "${tmpdir}"

  local fabric_bins=(peer orderer configtxgen configtxlator osnadmin discover cryptogen ledgerutil idemixgen)
  local b
  for b in "${fabric_bins[@]}"; do
    if [ -f "${tmpdir}/${b}" ]; then
      install -m 0755 "${tmpdir}/${b}" "${BIN_DIR}/${b}"
    fi
  done

  rm -rf "${tmpdir}"
}

install_fabric_ca_client() {
  local ca_archive="${DOWNLOAD_DIR}/hyperledger-fabric-ca-${PLATFORM}-${FABRIC_CA_VERSION}.tar.gz"
  local ca_url="https://github.com/hyperledger/fabric-ca/releases/download/v${FABRIC_CA_VERSION}/hyperledger-fabric-ca-${PLATFORM}-${FABRIC_CA_VERSION}.tar.gz"
  local tmpdir

  download_archive "${ca_url}" "${ca_archive}"

  tmpdir="$(mktemp -d)"
  tar -xzf "${ca_archive}" -C "${tmpdir}"

  if [ ! -f "${tmpdir}/fabric-ca-client" ]; then
    echo "Error: fabric-ca-client not found in extracted archive" >&2
    rm -rf "${tmpdir}"
    exit 1
  fi

  install -m 0755 "${tmpdir}/fabric-ca-client" "${BIN_DIR}/fabric-ca-client"
  rm -rf "${tmpdir}"
}

print_next_steps() {
  cat <<EOF

Done. Local CLI binaries are installed in:
  ${BIN_DIR}

Add this to your shell before running scripts:
  export PATH="${BIN_DIR}:\$PATH"
  export FABRIC_CFG_PATH="${ROOT_DIR}/config"

Quick check:
  peer version
  configtxgen --version
  fabric-ca-client version
EOF
}

main() {
  parse_args "$@"

  mkdir -p "${DOWNLOAD_DIR}" "${BIN_DIR}"

  if [ "${CHECK_ONLY}" = true ]; then
    if verify_local_cli; then
      log "CLI check passed in ${BIN_DIR}"
      exit 0
    fi

    echo "CLI check failed in ${BIN_DIR}. Run without --check to install." >&2
    exit 1
  fi

  require_binary curl
  require_binary tar
  require_binary install

  detect_platform
  log "Platform: ${PLATFORM}"
  log "Fabric: v${FABRIC_VERSION}, Fabric-CA: v${FABRIC_CA_VERSION}"

  install_fabric_binaries
  install_fabric_ca_client

  verify_local_cli
  print_next_steps
}

main "$@"

