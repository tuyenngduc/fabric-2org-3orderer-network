#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NETWORK_COMPOSE="${ROOT_DIR}/config/docker-compose-network.yaml"
CA_COMPOSE="${ROOT_DIR}/config/docker-compose-ca.yaml"
NETWORK_ENV="${ROOT_DIR}/config/.env.network"

WITH_VOLUMES=false
WITH_ARTIFACTS=false
YES=false
DRY_RUN=false

VOLUMES=(
  config_orderer1.example.com
  config_orderer2.example.com
  config_orderer3.example.com
  config_peer0.org1.example.com
  config_peer1.org1.example.com
  config_peer0.org2.example.com
  config_peer1.org2.example.com
)

ARTIFACTS=(
  "${ROOT_DIR}/channel-artifacts/mychannel.block"
  "${ROOT_DIR}/channel-artifacts/Org1MSPanchors.tx"
  "${ROOT_DIR}/channel-artifacts/Org2MSPanchors.tx"
)

usage() {
  cat <<'EOF'
Usage: ./scripts/clean-reset.sh [options]

Stop Fabric stacks and optionally purge local ledger/channel artifacts.

Options:
  --with-volumes     Remove known Docker volumes for orderer/peer ledgers
  --with-artifacts   Remove generated channel artifacts (mychannel.block, anchors tx)
  --all              Equivalent to --with-volumes --with-artifacts
  --yes              Skip destructive confirmation prompt
  --dry-run          Print actions without executing them
  -h, --help         Show this help

Examples:
  ./scripts/clean-reset.sh
  ./scripts/clean-reset.sh --all --yes
  ./scripts/clean-reset.sh --with-volumes --dry-run
EOF
}

run_cmd() {
  if [ "${DRY_RUN}" = true ]; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

confirm_if_needed() {
  if [ "${DRY_RUN}" = true ]; then
    return 0
  fi

  if [ "${YES}" = true ]; then
    return 0
  fi

  if [ "${WITH_VOLUMES}" = true ] || [ "${WITH_ARTIFACTS}" = true ]; then
    echo "Warning: this will delete local data (volumes/artifacts)."
    read -r -p "Type 'yes' to continue: " answer
    if [ "${answer}" != "yes" ]; then
      echo "Aborted."
      exit 1
    fi
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --with-volumes)
        WITH_VOLUMES=true
        ;;
      --with-artifacts)
        WITH_ARTIFACTS=true
        ;;
      --all)
        WITH_VOLUMES=true
        WITH_ARTIFACTS=true
        ;;
      --yes)
        YES=true
        ;;
      --dry-run)
        DRY_RUN=true
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
  done
}

remove_volumes() {
  for vol in "${VOLUMES[@]}"; do
    if [ "${DRY_RUN}" = true ]; then
      echo "[dry-run] docker volume rm ${vol}"
      continue
    fi

    docker volume rm "${vol}" >/dev/null 2>&1 || true
    echo "Removed volume (if existed): ${vol}"
  done
}

remove_artifacts() {
  for path in "${ARTIFACTS[@]}"; do
    run_cmd "rm -f \"${path}\""
    echo "Removed artifact (if existed): ${path}"
  done
}

main() {
  parse_args "$@"

  if [ ! -f "${NETWORK_COMPOSE}" ] || [ ! -f "${CA_COMPOSE}" ]; then
    echo "Error: compose files not found under ${ROOT_DIR}/config" >&2
    exit 1
  fi

  echo "==> Stopping runtime network stack"
  run_cmd "docker compose --env-file \"${NETWORK_ENV}\" -f \"${NETWORK_COMPOSE}\" down --remove-orphans || true"

  echo "==> Stopping CA stack"
  run_cmd "docker compose -f \"${CA_COMPOSE}\" down --remove-orphans || true"

  confirm_if_needed

  if [ "${WITH_VOLUMES}" = true ]; then
    echo "==> Removing ledger volumes"
    remove_volumes
  fi

  if [ "${WITH_ARTIFACTS}" = true ]; then
    echo "==> Removing channel artifacts"
    remove_artifacts
  fi

  echo "Done."
}

main "$@"

