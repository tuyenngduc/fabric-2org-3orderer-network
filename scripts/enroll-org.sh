#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/enroll-org.sh ORG_NAME ORG_DOMAIN CA_PORT CA_NAME

Examples:
  ./scripts/enroll-org.sh org1 org1.example.com 7054 ca-org1
  ./scripts/enroll-org.sh org2 org2.example.com 8054 ca-org2
  ./scripts/enroll-org.sh orderer example.com 9054 ca-orderer

Optional environment variables:
  CA_HOST          (default: localhost)
  CA_ADMIN_USER    (default: admin)
  CA_ADMIN_PASS    (default: adminpw)
  TLS_CERT         (default: organizations/fabric-ca/<ORG_NAME>/tls-cert.pem)
  PEER_COUNT       (default: 2 for peer orgs)
  ORDERER_COUNT    (default: 3 for orderer org)
EOF
}

if [ "$#" -ne 4 ]; then
  usage
  exit 1
fi

ORG_NAME="$1"
ORG_DOMAIN="$2"
CA_PORT="$3"
CA_NAME="$4"

ORG_NAME_LOWER="$(printf '%s' "${ORG_NAME}" | tr '[:upper:]' '[:lower:]')"
IS_ORDERER_ORG=false
if [[ "${ORG_NAME_LOWER}" == orderer* ]]; then
  IS_ORDERER_ORG=true
fi

CA_HOST="${CA_HOST:-localhost}"
CA_ADMIN_USER="${CA_ADMIN_USER:-admin}"
CA_ADMIN_PASS="${CA_ADMIN_PASS:-adminpw}"

if ${IS_ORDERER_ORG}; then
  CA_DIR_NAME="ordererOrg"
else
  CA_DIR_NAME="${ORG_NAME}"
fi
TLS_CERT="${TLS_CERT:-${ROOT_DIR}/organizations/fabric-ca/${CA_DIR_NAME}/tls-cert.pem}"

require_binary() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' is not installed or not in PATH" >&2
    exit 1
  fi
}

require_file() {
  if [ ! -f "$1" ]; then
    echo "Error: required file '$1' was not found" >&2
    exit 1
  fi
}

copy_first_file() {
  local src_dir="$1"
  local dst_file="$2"
  local src_file

  src_file=$(find "${src_dir}" -maxdepth 1 -type f | head -n 1)
  if [ -z "${src_file}" ]; then
    echo "Error: no source file found in ${src_dir}" >&2
    exit 1
  fi

  cp "${src_file}" "${dst_file}"
}

ensure_msp_structure() {
  local msp_dir="$1"
  local tls_ca_src="$2"
  local tls_ca_dst="${msp_dir}/tlscacerts/ca.crt"

  mkdir -p "${msp_dir}/cacerts" "${msp_dir}/keystore" "${msp_dir}/signcerts" "${msp_dir}/tlscacerts"

  # Keep reruns safe when source already points to the destination file.
  if [ "$(realpath "${tls_ca_src}")" != "$(realpath -m "${tls_ca_dst}")" ]; then
    cp "${tls_ca_src}" "${tls_ca_dst}"
  fi
}

register_identity() {
  local name="$1"
  local secret="$2"
  local type="$3"
  local out

  set +e
  out=$(fabric-ca-client register \
    --caname "${CA_NAME}" \
    --id.name "${name}" \
    --id.secret "${secret}" \
    --id.type "${type}" \
    --tls.certfiles "${TLS_CERT}" 2>&1)
  local rc=$?
  set -e

  if [ ${rc} -eq 0 ]; then
    return 0
  fi

  if printf '%s' "${out}" | grep -qi "already registered"; then
    echo "    Identity '${name}' already registered, skipping"
    return 0
  fi

  echo "${out}" >&2
  return ${rc}
}

write_node_ous_config() {
  local org_msp_dir="$1"

  mkdir -p "${org_msp_dir}"
  cat > "${org_msp_dir}/config.yaml" <<EOF
NodeOUs:
  Enable: true
  ClientOUIdentifier:
    Certificate: cacerts/${CA_HOST}-${CA_PORT}-${CA_NAME}.pem
    OrganizationalUnitIdentifier: client
  PeerOUIdentifier:
    Certificate: cacerts/${CA_HOST}-${CA_PORT}-${CA_NAME}.pem
    OrganizationalUnitIdentifier: peer
  AdminOUIdentifier:
    Certificate: cacerts/${CA_HOST}-${CA_PORT}-${CA_NAME}.pem
    OrganizationalUnitIdentifier: admin
  OrdererOUIdentifier:
    Certificate: cacerts/${CA_HOST}-${CA_PORT}-${CA_NAME}.pem
    OrganizationalUnitIdentifier: orderer
EOF
}

enroll_peer_org() {
  local peer_org_dir="${ROOT_DIR}/organizations/peerOrganizations/${ORG_DOMAIN}"
  local peer_count="${PEER_COUNT:-2}"
  local org_admin_id="${ORG_NAME}admin"

  mkdir -p "${peer_org_dir}"
  export FABRIC_CA_CLIENT_HOME="${peer_org_dir}"

  echo "==> Enrolling CA bootstrap admin for ${ORG_DOMAIN}"
  rm -rf "${peer_org_dir}/msp"
  fabric-ca-client enroll \
    -u "https://${CA_ADMIN_USER}:${CA_ADMIN_PASS}@${CA_HOST}:${CA_PORT}" \
    --caname "${CA_NAME}" \
    --tls.certfiles "${TLS_CERT}"

  write_node_ous_config "${peer_org_dir}/msp"

  echo "==> Registering peer identities for ${ORG_DOMAIN}"
  local i
  for ((i=0; i<peer_count; i++)); do
    register_identity "peer${i}" "peer${i}pw" peer
  done
  register_identity "${org_admin_id}" "${org_admin_id}pw" admin
  register_identity user1 user1pw client

  for ((i=0; i<peer_count; i++)); do
    local peer_dir="${peer_org_dir}/peers/peer${i}.${ORG_DOMAIN}"

    echo "==> Enrolling peer${i} MSP"
    rm -rf "${peer_dir}/msp"
    fabric-ca-client enroll \
      -u "https://peer${i}:peer${i}pw@${CA_HOST}:${CA_PORT}" \
      --caname "${CA_NAME}" \
      -M "${peer_dir}/msp" \
      --csr.hosts "peer${i}.${ORG_DOMAIN}" \
      --csr.hosts localhost \
      --tls.certfiles "${TLS_CERT}"
    cp "${peer_org_dir}/msp/config.yaml" "${peer_dir}/msp/config.yaml"

    echo "==> Enrolling peer${i} TLS certs"
    rm -rf "${peer_dir}/tls"
    fabric-ca-client enroll \
      -u "https://peer${i}:peer${i}pw@${CA_HOST}:${CA_PORT}" \
      --caname "${CA_NAME}" \
      -M "${peer_dir}/tls" \
      --enrollment.profile tls \
      --csr.hosts "peer${i}.${ORG_DOMAIN}" \
      --csr.hosts localhost \
      --tls.certfiles "${TLS_CERT}"

    copy_first_file "${peer_dir}/tls/tlscacerts" "${peer_dir}/tls/ca.crt"
    copy_first_file "${peer_dir}/tls/signcerts" "${peer_dir}/tls/server.crt"
    copy_first_file "${peer_dir}/tls/keystore" "${peer_dir}/tls/server.key"

    ensure_msp_structure "${peer_dir}/msp" "${peer_dir}/tls/ca.crt"
  done

  local user1_dir="${peer_org_dir}/users/User1@${ORG_DOMAIN}"
  local org_admin_dir="${peer_org_dir}/users/Admin@${ORG_DOMAIN}"

  echo "==> Enrolling user1 MSP"
  rm -rf "${user1_dir}/msp"
  fabric-ca-client enroll \
    -u "https://user1:user1pw@${CA_HOST}:${CA_PORT}" \
    --caname "${CA_NAME}" \
    -M "${user1_dir}/msp" \
    --tls.certfiles "${TLS_CERT}"
  cp "${peer_org_dir}/msp/config.yaml" "${user1_dir}/msp/config.yaml"

  echo "==> Enrolling org admin MSP"
  rm -rf "${org_admin_dir}/msp"
  fabric-ca-client enroll \
    -u "https://${org_admin_id}:${org_admin_id}pw@${CA_HOST}:${CA_PORT}" \
    --caname "${CA_NAME}" \
    -M "${org_admin_dir}/msp" \
    --tls.certfiles "${TLS_CERT}"
  cp "${peer_org_dir}/msp/config.yaml" "${org_admin_dir}/msp/config.yaml"

  mkdir -p "${peer_org_dir}/msp/tlscacerts" "${peer_org_dir}/tlsca" "${peer_org_dir}/ca"
  copy_first_file "${peer_org_dir}/peers/peer0.${ORG_DOMAIN}/tls/tlscacerts" "${peer_org_dir}/msp/tlscacerts/ca.crt"
  copy_first_file "${peer_org_dir}/peers/peer0.${ORG_DOMAIN}/tls/tlscacerts" "${peer_org_dir}/tlsca/tlsca.${ORG_DOMAIN}-cert.pem"
  copy_first_file "${peer_org_dir}/peers/peer0.${ORG_DOMAIN}/msp/cacerts" "${peer_org_dir}/ca/ca.${ORG_DOMAIN}-cert.pem"

  ensure_msp_structure "${peer_org_dir}/msp" "${peer_org_dir}/msp/tlscacerts/ca.crt"
  ensure_msp_structure "${user1_dir}/msp" "${peer_org_dir}/msp/tlscacerts/ca.crt"
  ensure_msp_structure "${org_admin_dir}/msp" "${peer_org_dir}/msp/tlscacerts/ca.crt"

  echo "Done. Peer organization enrolled at: ${peer_org_dir}"
}

enroll_orderer_org() {
  local orderer_org_dir="${ROOT_DIR}/organizations/ordererOrganizations/${ORG_DOMAIN}"
  local orderer_count="${ORDERER_COUNT:-3}"
  local admin_id="ordererAdmin"
  local admin_user_dir="${orderer_org_dir}/users/Admin@${ORG_DOMAIN}"

  mkdir -p "${orderer_org_dir}"
  export FABRIC_CA_CLIENT_HOME="${orderer_org_dir}"

  echo "==> Enrolling CA bootstrap admin for orderer org ${ORG_DOMAIN}"
  rm -rf "${orderer_org_dir}/msp"
  fabric-ca-client enroll \
    -u "https://${CA_ADMIN_USER}:${CA_ADMIN_PASS}@${CA_HOST}:${CA_PORT}" \
    --caname "${CA_NAME}" \
    --tls.certfiles "${TLS_CERT}"

  write_node_ous_config "${orderer_org_dir}/msp"

  echo "==> Registering orderer identities"
  local i
  for ((i=1; i<=orderer_count; i++)); do
    register_identity "orderer${i}" "orderer${i}pw" orderer
  done
  register_identity "${admin_id}" "${admin_id}pw" admin

  for ((i=1; i<=orderer_count; i++)); do
    local orderer_host="orderer${i}.${ORG_DOMAIN}"
    local orderer_dir="${orderer_org_dir}/orderers/${orderer_host}"

    echo "==> Enrolling ${orderer_host} MSP"
    rm -rf "${orderer_dir}/msp"
    fabric-ca-client enroll \
      -u "https://orderer${i}:orderer${i}pw@${CA_HOST}:${CA_PORT}" \
      --caname "${CA_NAME}" \
      -M "${orderer_dir}/msp" \
      --csr.hosts "${orderer_host}" \
      --csr.hosts localhost \
      --tls.certfiles "${TLS_CERT}"
    cp "${orderer_org_dir}/msp/config.yaml" "${orderer_dir}/msp/config.yaml"

    echo "==> Enrolling ${orderer_host} TLS certs"
    rm -rf "${orderer_dir}/tls"
    fabric-ca-client enroll \
      -u "https://orderer${i}:orderer${i}pw@${CA_HOST}:${CA_PORT}" \
      --caname "${CA_NAME}" \
      -M "${orderer_dir}/tls" \
      --enrollment.profile tls \
      --csr.hosts "${orderer_host}" \
      --csr.hosts localhost \
      --tls.certfiles "${TLS_CERT}"

    copy_first_file "${orderer_dir}/tls/tlscacerts" "${orderer_dir}/tls/ca.crt"
    copy_first_file "${orderer_dir}/tls/signcerts" "${orderer_dir}/tls/server.crt"
    copy_first_file "${orderer_dir}/tls/keystore" "${orderer_dir}/tls/server.key"
    ensure_msp_structure "${orderer_dir}/msp" "${orderer_dir}/tls/ca.crt"
  done

  echo "==> Enrolling orderer admin MSP"
  rm -rf "${admin_user_dir}/msp"
  fabric-ca-client enroll \
    -u "https://${admin_id}:${admin_id}pw@${CA_HOST}:${CA_PORT}" \
    --caname "${CA_NAME}" \
    -M "${admin_user_dir}/msp" \
    --tls.certfiles "${TLS_CERT}"
  cp "${orderer_org_dir}/msp/config.yaml" "${admin_user_dir}/msp/config.yaml"

  echo "==> Enrolling orderer admin TLS client cert"
  rm -rf "${admin_user_dir}/tls"
  fabric-ca-client enroll \
    -u "https://${admin_id}:${admin_id}pw@${CA_HOST}:${CA_PORT}" \
    --caname "${CA_NAME}" \
    -M "${admin_user_dir}/tls" \
    --enrollment.profile tls \
    --csr.hosts "admin.${ORG_DOMAIN}" \
    --csr.hosts localhost \
    --tls.certfiles "${TLS_CERT}"

  copy_first_file "${admin_user_dir}/tls/signcerts" "${admin_user_dir}/tls/client.crt"
  copy_first_file "${admin_user_dir}/tls/keystore" "${admin_user_dir}/tls/client.key"
  copy_first_file "${admin_user_dir}/tls/tlscacerts" "${admin_user_dir}/tls/ca.crt"

  mkdir -p "${orderer_org_dir}/msp/tlscacerts" "${orderer_org_dir}/tlsca" "${orderer_org_dir}/ca"
  copy_first_file "${orderer_org_dir}/orderers/orderer1.${ORG_DOMAIN}/tls/tlscacerts" "${orderer_org_dir}/msp/tlscacerts/ca.crt"
  copy_first_file "${orderer_org_dir}/orderers/orderer1.${ORG_DOMAIN}/tls/tlscacerts" "${orderer_org_dir}/tlsca/tlsca.${ORG_DOMAIN}-cert.pem"
  copy_first_file "${orderer_org_dir}/orderers/orderer1.${ORG_DOMAIN}/msp/cacerts" "${orderer_org_dir}/ca/ca.${ORG_DOMAIN}-cert.pem"

  ensure_msp_structure "${orderer_org_dir}/msp" "${orderer_org_dir}/msp/tlscacerts/ca.crt"
  ensure_msp_structure "${admin_user_dir}/msp" "${orderer_org_dir}/msp/tlscacerts/ca.crt"

  echo "Done. Orderer organization enrolled at: ${orderer_org_dir}"
}

main() {
  require_binary fabric-ca-client
  require_file "${TLS_CERT}"

  if ${IS_ORDERER_ORG}; then
    enroll_orderer_org
  else
    enroll_peer_org
  fi
}

main "$@"

