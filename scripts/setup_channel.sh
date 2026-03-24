#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGTX_PATH="${CONFIGTX_PATH:-${ROOT_DIR}/config}"
if [ -z "${FABRIC_CFG_PATH:-}" ]; then
  export FABRIC_CFG_PATH="${ROOT_DIR}/config"
fi

CHANNEL_NAME="${CHANNEL_NAME:-mychannel}"
PROFILE="${PROFILE:-TwoOrgsApplicationGenesis}"
CHANNEL_ARTIFACTS_DIR="${ROOT_DIR}/channel-artifacts"
CHANNEL_BLOCK="${CHANNEL_ARTIFACTS_DIR}/${CHANNEL_NAME}.block"
ORG1_ANCHOR_TX="${CHANNEL_ARTIFACTS_DIR}/Org1MSPanchors.tx"
ORG2_ANCHOR_TX="${CHANNEL_ARTIFACTS_DIR}/Org2MSPanchors.tx"

ORDERER_ENDPOINT="${ORDERER_ENDPOINT:-localhost:7050}"
ORDERER_HOSTNAME_OVERRIDE="${ORDERER_HOSTNAME_OVERRIDE:-orderer1.example.com}"
ORDERER_CA="${ORDERER_CA:-${ROOT_DIR}/organizations/ordererOrganizations/example.com/orderers/orderer1.example.com/tls/ca.crt}"
ORDERER_ADMIN_ENDPOINTS="${ORDERER_ADMIN_ENDPOINTS:-localhost:9443,localhost:10443,localhost:11443}"
OSN_TLS_CA="${OSN_TLS_CA:-${ROOT_DIR}/organizations/ordererOrganizations/example.com/orderers/orderer1.example.com/tls/ca.crt}"
OSN_CLIENT_CERT="${OSN_CLIENT_CERT:-${ROOT_DIR}/organizations/ordererOrganizations/example.com/users/Admin@example.com/tls/client.crt}"
OSN_CLIENT_KEY="${OSN_CLIENT_KEY:-${ROOT_DIR}/organizations/ordererOrganizations/example.com/users/Admin@example.com/tls/client.key}"

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

require_dir() {
  if [ ! -d "$1" ]; then
    echo "Error: required directory '$1' does not exist" >&2
    exit 1
  fi
}

set_peer_globals() {
  local org="$1"
  local peer_index="$2"

  if [ "$org" = "1" ]; then
    export CORE_PEER_LOCALMSPID="Org1MSP"
    export CORE_PEER_MSPCONFIGPATH="${ROOT_DIR}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp"

    if [ "$peer_index" = "0" ]; then
      export CORE_PEER_ADDRESS="localhost:7051"
      export CORE_PEER_TLS_ROOTCERT_FILE="${ROOT_DIR}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
    else
      export CORE_PEER_ADDRESS="localhost:8051"
      export CORE_PEER_TLS_ROOTCERT_FILE="${ROOT_DIR}/organizations/peerOrganizations/org1.example.com/peers/peer1.org1.example.com/tls/ca.crt"
    fi
  elif [ "$org" = "2" ]; then
    export CORE_PEER_LOCALMSPID="Org2MSP"
    export CORE_PEER_MSPCONFIGPATH="${ROOT_DIR}/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp"

    if [ "$peer_index" = "0" ]; then
      export CORE_PEER_ADDRESS="localhost:9051"
      export CORE_PEER_TLS_ROOTCERT_FILE="${ROOT_DIR}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt"
    else
      export CORE_PEER_ADDRESS="localhost:10051"
      export CORE_PEER_TLS_ROOTCERT_FILE="${ROOT_DIR}/organizations/peerOrganizations/org2.example.com/peers/peer1.org2.example.com/tls/ca.crt"
    fi
  else
    echo "Error: unsupported org '$org'" >&2
    exit 1
  fi

  export CORE_PEER_TLS_ENABLED=true
}

verify_prerequisites() {
  require_binary configtxgen
  require_binary osnadmin
  require_binary peer

  require_file "${CONFIGTX_PATH}/configtx.yaml"
  require_file "${FABRIC_CFG_PATH}/core.yaml"
  require_file "${ORDERER_CA}"
  require_file "${OSN_TLS_CA}"
  require_file "${OSN_CLIENT_CERT}"
  require_file "${OSN_CLIENT_KEY}"

  require_dir "${ROOT_DIR}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp"
  require_dir "${ROOT_DIR}/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp"
}

generate_channel_artifacts() {
  mkdir -p "${CHANNEL_ARTIFACTS_DIR}"

  echo "==> Generating channel block: ${CHANNEL_BLOCK}"
  configtxgen \
    -configPath "${CONFIGTX_PATH}" \
    -profile "${PROFILE}" \
    -channelID "${CHANNEL_NAME}" \
    -outputBlock "${CHANNEL_BLOCK}"

  echo "==> Generating anchor peer update tx for Org1"
  configtxgen \
    -configPath "${CONFIGTX_PATH}" \
    -profile "${PROFILE}" \
    -channelID "${CHANNEL_NAME}" \
    -asOrg Org1MSP \
    -outputAnchorPeersUpdate "${ORG1_ANCHOR_TX}"

  echo "==> Generating anchor peer update tx for Org2"
  configtxgen \
    -configPath "${CONFIGTX_PATH}" \
    -profile "${PROFILE}" \
    -channelID "${CHANNEL_NAME}" \
    -asOrg Org2MSP \
    -outputAnchorPeersUpdate "${ORG2_ANCHOR_TX}"
}

orderer_has_channel() {
  local endpoint="$1"
  osnadmin channel list \
    -o "${endpoint}" \
    --ca-file "${OSN_TLS_CA}" \
    --client-cert "${OSN_CLIENT_CERT}" \
    --client-key "${OSN_CLIENT_KEY}" 2>/dev/null | grep -q "\"name\":\"${CHANNEL_NAME}\""
}

join_orderers_to_channel() {
  IFS=',' read -r -a endpoints <<<"${ORDERER_ADMIN_ENDPOINTS}"

  for endpoint in "${endpoints[@]}"; do
    echo "==> Ensuring orderer at ${endpoint} has channel ${CHANNEL_NAME}"
    if orderer_has_channel "${endpoint}"; then
      echo "    Channel already present on ${endpoint}, skipping join"
      continue
    fi

    osnadmin channel join \
      --channelID "${CHANNEL_NAME}" \
      --config-block "${CHANNEL_BLOCK}" \
      -o "${endpoint}" \
      --ca-file "${OSN_TLS_CA}" \
      --client-cert "${OSN_CLIENT_CERT}" \
      --client-key "${OSN_CLIENT_KEY}"
  done
}

join_peer() {
  local org="$1"
  local peer_index="$2"

  set_peer_globals "${org}" "${peer_index}"

  if peer channel getinfo -c "${CHANNEL_NAME}" >/dev/null 2>&1; then
    echo "==> peer${peer_index}.org${org}.example.com already joined ${CHANNEL_NAME}, skipping"
    return
  fi

  echo "==> Joining peer${peer_index}.org${org}.example.com to ${CHANNEL_NAME}"
  peer channel join -b "${CHANNEL_BLOCK}"
}

update_anchor_peers() {
  echo "==> Updating anchor peers using config fetch/compute flow"
  CHANNEL_NAME="${CHANNEL_NAME}" \
  ORDERER_ENDPOINT="${ORDERER_ENDPOINT}" \
  ORDERER_HOSTNAME_OVERRIDE="${ORDERER_HOSTNAME_OVERRIDE}" \
  ORDERER_CA="${ORDERER_CA}" \
  FABRIC_CFG_PATH="${FABRIC_CFG_PATH}" \
    "${ROOT_DIR}/scripts/update-anchor-peers.sh"
}

print_chaincode_template() {
  cat <<'EOF'

Template: package and install a Golang chaincode

```bash
# 1) Set chaincode metadata
export CC_NAME=mycc
export CC_VERSION=1.0
export CC_SEQUENCE=1
export CC_LABEL=${CC_NAME}_${CC_VERSION}
export CC_SRC_PATH=/absolute/path/to/chaincode-go
export CC_PACKAGE_FILE=${CC_LABEL}.tar.gz

# 2) Package chaincode (run once)
peer lifecycle chaincode package "${CC_PACKAGE_FILE}" \
  --path "${CC_SRC_PATH}" \
  --lang golang \
  --label "${CC_LABEL}"

# 3) Install on each peer (repeat with each peer admin context)
# Example: Org1 peer0
export CORE_PEER_LOCALMSPID=Org1MSP
export CORE_PEER_MSPCONFIGPATH=/path/to/fabric/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
export CORE_PEER_ADDRESS=localhost:7051
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_TLS_ROOTCERT_FILE=/path/to/fabric/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
peer lifecycle chaincode install "${CC_PACKAGE_FILE}"
```
EOF
}

main() {
  verify_prerequisites
  generate_channel_artifacts
  join_orderers_to_channel

  join_peer 1 0
  join_peer 1 1
  join_peer 2 0
  join_peer 2 1

  update_anchor_peers
  print_chaincode_template

  echo "==> Channel setup complete for ${CHANNEL_NAME}"
}

main "$@"
