#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "${FABRIC_CFG_PATH:-}" ]; then
  export FABRIC_CFG_PATH="${ROOT_DIR}/config"
fi

CHANNEL_NAME="${CHANNEL_NAME:-mychannel}"
ORDERER_ENDPOINT="${ORDERER_ENDPOINT:-localhost:7050}"
ORDERER_HOSTNAME_OVERRIDE="${ORDERER_HOSTNAME_OVERRIDE:-orderer1.example.com}"
ORDERER_CA="${ORDERER_CA:-${ROOT_DIR}/organizations/ordererOrganizations/example.com/orderers/orderer1.example.com/tls/ca.crt}"
WORK_DIR="${WORK_DIR:-${ROOT_DIR}/channel-artifacts/anchor-updates}"

require_binary() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' is not installed or not in PATH" >&2
    exit 1
  fi
}

require_file() {
  if [ ! -f "$1" ]; then
    echo "Error: required file '$1' does not exist" >&2
    exit 1
  fi
}

fetch_config_block_with_retry() {
  local block_pb="$1"
  local max_attempts="${FETCH_CONFIG_MAX_ATTEMPTS:-12}"
  local sleep_seconds="${FETCH_CONFIG_SLEEP_SECONDS:-3}"
  local attempt=1

  while [ "${attempt}" -le "${max_attempts}" ]; do
    set +e
    peer channel fetch config "${block_pb}" \
      -c "${CHANNEL_NAME}" \
      -o "${ORDERER_ENDPOINT}" \
      --ordererTLSHostnameOverride "${ORDERER_HOSTNAME_OVERRIDE}" \
      --tls \
      --cafile "${ORDERER_CA}" >/tmp/fabric_fetch_config.out 2>&1
    local rc=$?
    set -e

    if [ ${rc} -eq 0 ]; then
      return 0
    fi

    if [ "${attempt}" -eq "${max_attempts}" ]; then
      cat /tmp/fabric_fetch_config.out >&2
      return ${rc}
    fi

    echo "    Waiting for orderer deliver service (${attempt}/${max_attempts}), retrying in ${sleep_seconds}s..."
    sleep "${sleep_seconds}"
    attempt=$((attempt + 1))
  done
}

set_peer_globals() {
  local org="$1"

  if [ "$org" = "1" ]; then
    export CORE_PEER_LOCALMSPID="Org1MSP"
    export CORE_PEER_MSPCONFIGPATH="${ROOT_DIR}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp"
    export CORE_PEER_ADDRESS="localhost:7051"
    export CORE_PEER_TLS_ROOTCERT_FILE="${ROOT_DIR}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
  elif [ "$org" = "2" ]; then
    export CORE_PEER_LOCALMSPID="Org2MSP"
    export CORE_PEER_MSPCONFIGPATH="${ROOT_DIR}/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp"
    export CORE_PEER_ADDRESS="localhost:9051"
    export CORE_PEER_TLS_ROOTCERT_FILE="${ROOT_DIR}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt"
  else
    echo "Error: unsupported org '$org'" >&2
    exit 1
  fi

  export CORE_PEER_TLS_ENABLED=true
}

json_extract_config() {
  local block_json="$1"
  local config_json="$2"

  jq '.data.data[0].payload.data.config' "${block_json}" >"${config_json}"
}

json_patch_anchor_peer() {
  local config_in="$1"
  local config_out="$2"
  local msp_id="$3"
  local host="$4"
  local port="$5"

  jq \
    --arg msp_id "${msp_id}" \
    --arg host "${host}" \
    --argjson port "${port}" \
    '.channel_group.groups.Application.groups[$msp_id].values.AnchorPeers = {
      mod_policy: "Admins",
      value: {anchor_peers: [{host: $host, port: $port}]},
      version: "0"
    }' \
    "${config_in}" >"${config_out}"
}

build_update_envelope() {
  local update_json="$1"
  local envelope_json="$2"
  local channel_name="$3"

  jq \
    --arg channel_name "${channel_name}" \
    '{
      payload: {
        header: {
          channel_header: {
            channel_id: $channel_name,
            type: 2
          }
        },
        data: {
          config_update: .
        }
      }
    }' "${update_json}" >"${envelope_json}"
}

update_anchor_for_org() {
  local org="$1"
  local msp_id="$2"
  local anchor_host="$3"
  local anchor_port="$4"

  set_peer_globals "${org}"

  local prefix="${WORK_DIR}/${msp_id}"
  local block_pb="${prefix}_config_block.pb"
  local block_json="${prefix}_config_block.json"
  local config_json="${prefix}_config.json"
  local modified_json="${prefix}_modified_config.json"
  local config_pb="${prefix}_config.pb"
  local modified_pb="${prefix}_modified_config.pb"
  local update_pb="${prefix}_update.pb"
  local update_json="${prefix}_update.json"
  local envelope_json="${prefix}_anchors_envelope.json"
  local envelope_pb="${prefix}_anchors_envelope.pb"

  echo "==> Fetching latest config block for ${CHANNEL_NAME} as ${msp_id}"
  fetch_config_block_with_retry "${block_pb}"

  configtxlator proto_decode --input "${block_pb}" --type common.Block --output "${block_json}"
  json_extract_config "${block_json}" "${config_json}"
  json_patch_anchor_peer "${config_json}" "${modified_json}" "${msp_id}" "${anchor_host}" "${anchor_port}"

  configtxlator proto_encode --input "${config_json}" --type common.Config --output "${config_pb}"
  configtxlator proto_encode --input "${modified_json}" --type common.Config --output "${modified_pb}"

  local compute_out
  set +e
  compute_out=$(configtxlator compute_update \
    --channel_id "${CHANNEL_NAME}" \
    --original "${config_pb}" \
    --updated "${modified_pb}" \
    --output "${update_pb}" 2>&1)
  local compute_rc=$?
  set -e

  if [ ${compute_rc} -ne 0 ]; then
    if printf '%s' "${compute_out}" | grep -q "no differences detected"; then
      echo "==> ${msp_id} anchor peer already up to date, skipping"
      return 0
    fi
    echo "${compute_out}" >&2
    return ${compute_rc}
  fi

  configtxlator proto_decode --input "${update_pb}" --type common.ConfigUpdate --output "${update_json}"
  build_update_envelope "${update_json}" "${envelope_json}" "${CHANNEL_NAME}"
  configtxlator proto_encode --input "${envelope_json}" --type common.Envelope --output "${envelope_pb}"

  echo "==> Submitting anchor peer update for ${msp_id}"
  peer channel update \
    -f "${envelope_pb}" \
    -c "${CHANNEL_NAME}" \
    -o "${ORDERER_ENDPOINT}" \
    --ordererTLSHostnameOverride "${ORDERER_HOSTNAME_OVERRIDE}" \
    --tls \
    --cafile "${ORDERER_CA}"
}

main() {
  require_binary peer
  require_binary configtxlator
  require_binary jq
  require_file "${ORDERER_CA}"

  mkdir -p "${WORK_DIR}"

  update_anchor_for_org 1 Org1MSP peer0.org1.example.com 7051
  update_anchor_for_org 2 Org2MSP peer0.org2.example.com 9051

  echo "==> Anchor peer updates completed for channel ${CHANNEL_NAME}"
}

main "$@"

