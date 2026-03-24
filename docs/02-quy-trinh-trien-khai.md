# 02 - Quy trình triển khai mạng Fabric (chi tiết từng bước)


## 0) Quy ước dùng chung

```bash
# Đặt đường dẫn repo local của bạn (thay bằng path thật)
export FABRIC_HOME="/path/to/fabric"
cd "${FABRIC_HOME}"
```

Repo hỗ trợ 2 cách chạy CLI Fabric:

- `MODE A` (khuyến nghị khi vận hành lâu dài): cài binary Fabric/Fabric-CA trên host.
- `MODE B` (dễ onboard): chạy CLI trong container, không cần cài binary host.

### 0.1 Thiết lập CLI cho MODE A (host binary)

```bash
export PATH="/opt/hyperledger/fabric/bin:$PATH"
export FABRIC_CFG_PATH="${FABRIC_HOME}/config"
```

### 0.2 Thiết lập CLI cho MODE B (containerized)

```bash
alias ftools='docker run --rm --network host -v "${FABRIC_HOME}":/workspace -w /workspace hyperledger/fabric-tools:2.5 bash -lc'
alias fca='docker run --rm --network host -v "${FABRIC_HOME}":/workspace -w /workspace hyperledger/fabric-ca:1.5.8 bash -lc'
```

## 1) Checklist trước khi chạy

- [ ] Docker daemon đang chạy
- [ ] Có `docker compose`
- [ ] Mở các cổng local theo compose
- [ ] Chọn 1 trong 2 mode CLI ở trên

## 2) Chuẩn bị môi trường

### 2.1 Kiểm tra version công cụ

```bash
docker --version
docker compose version
```

Nếu dùng `MODE A` thì kiểm tra thêm:

```bash
peer version
configtxgen --version
fabric-ca-client version
configtxlator version
osnadmin --help | head -n 5
```

Nếu dùng `MODE B` thì kiểm tra image CLI:

```bash
ftools 'peer version && configtxgen --version && configtxlator version && osnadmin --help | head -n 5'
fca 'fabric-ca-client version'
```

### 2.2 Chuẩn bị env runtime

```bash
cd "${FABRIC_HOME}"
cp -n config/.env.network.example config/.env.network
```

Sau đó chỉnh `COUCHDB_PASSWORD` trong `config/.env.network`.

## 3) Khởi động CA

```bash
cd "${FABRIC_HOME}"
docker compose -f config/docker-compose-ca.yaml up -d
docker compose -f config/docker-compose-ca.yaml ps
```

Kỳ vọng: `ca_org1`, `ca_org2`, `ca_orderer` ở trạng thái `Up`.

## 4) Enroll danh tính cho Org1, Org2, Orderer

Nếu dùng `MODE A`:

```bash
cd "${FABRIC_HOME}"
./scripts/enroll-org.sh org1 org1.example.com 7054 ca-org1
./scripts/enroll-org.sh org2 org2.example.com 8054 ca-org2
./scripts/enroll-org.sh orderer example.com 9054 ca-orderer
```

Nếu dùng `MODE B`:

```bash
cd "${FABRIC_HOME}"
fca './scripts/enroll-org.sh org1 org1.example.com 7054 ca-org1'
fca './scripts/enroll-org.sh org2 org2.example.com 8054 ca-org2'
fca './scripts/enroll-org.sh orderer example.com 9054 ca-orderer'
```

### 4.1 Kiểm tra nhanh output sau enroll

```bash
cd "${FABRIC_HOME}"
ls -la organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls
ls -la organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls
ls -la organizations/ordererOrganizations/example.com/orderers/orderer1.example.com/tls
ls -la organizations/ordererOrganizations/example.com/users/Admin@example.com/tls
```

Các file quan trọng cần có: `ca.crt`, `server.crt`, `server.key`; với admin orderer cần thêm `client.crt`, `client.key`.

## 5) Validate cấu hình trước khi chạy runtime

```bash
cd "${FABRIC_HOME}"
./scripts/validate-stack.sh
```

## 6) Khởi động runtime network

```bash
cd "${FABRIC_HOME}"
docker compose --env-file config/.env.network -f config/docker-compose-network.yaml up -d
docker compose --env-file config/.env.network -f config/docker-compose-network.yaml ps
```

Kỳ vọng: orderer/peer `Up`, couchdb `Up (healthy)`.

## 7) Tạo channel và join nodes

Nếu dùng `MODE A`:

```bash
cd "${FABRIC_HOME}"
export FABRIC_CFG_PATH="${FABRIC_HOME}/config"
./scripts/setup_channel.sh
```

Nếu dùng `MODE B`:

```bash
cd "${FABRIC_HOME}"
ftools 'export FABRIC_CFG_PATH=/workspace/config; ./scripts/setup_channel.sh'
```

Script sẽ tự tạo block channel, join orderer/peer và cập nhật anchor peer.

## 8) Kiểm tra sau triển khai

### 8.1 Kiểm tra channel trên orderer

`MODE A`:

```bash
cd "${FABRIC_HOME}"
osnadmin channel list \
  -o localhost:9443 \
  --ca-file organizations/ordererOrganizations/example.com/orderers/orderer1.example.com/tls/ca.crt \
  --client-cert organizations/ordererOrganizations/example.com/users/Admin@example.com/tls/client.crt \
  --client-key organizations/ordererOrganizations/example.com/users/Admin@example.com/tls/client.key
```

`MODE B`:

```bash
cd "${FABRIC_HOME}"
ftools 'osnadmin channel list -o localhost:9443 --ca-file organizations/ordererOrganizations/example.com/orderers/orderer1.example.com/tls/ca.crt --client-cert organizations/ordererOrganizations/example.com/users/Admin@example.com/tls/client.crt --client-key organizations/ordererOrganizations/example.com/users/Admin@example.com/tls/client.key'
```

Kỳ vọng: có channel `mychannel` trong danh sách.

### 8.2 Kiểm tra channel trên peer

`MODE A`:

```bash
cd "${FABRIC_HOME}"
export FABRIC_CFG_PATH="${FABRIC_HOME}/config"
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID=Org1MSP
export CORE_PEER_MSPCONFIGPATH="${FABRIC_HOME}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp"
export CORE_PEER_ADDRESS=localhost:7051
export CORE_PEER_TLS_ROOTCERT_FILE="${FABRIC_HOME}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
peer channel getinfo -c mychannel
```

`MODE B`:

```bash
cd "${FABRIC_HOME}"
ftools 'export FABRIC_CFG_PATH=/workspace/config; export CORE_PEER_TLS_ENABLED=true; export CORE_PEER_LOCALMSPID=Org1MSP; export CORE_PEER_MSPCONFIGPATH=/workspace/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp; export CORE_PEER_ADDRESS=localhost:7051; export CORE_PEER_TLS_ROOTCERT_FILE=/workspace/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt; peer channel getinfo -c mychannel'
```

Kỳ vọng: trả về `Blockchain info` với `height >= 1`.

## 9) Triển khai chaincode cơ bản

`setup_channel.sh` đã in template package/install. Ví dụ package nhanh:

```bash
export CC_NAME=mycc
export CC_VERSION=1.0
export CC_LABEL=${CC_NAME}_${CC_VERSION}
export CC_SRC_PATH=/absolute/path/to/chaincode-go
export CC_PACKAGE_FILE=${CC_LABEL}.tar.gz

peer lifecycle chaincode package "${CC_PACKAGE_FILE}" \
  --path "${CC_SRC_PATH}" \
  --lang golang \
  --label "${CC_LABEL}"
```

## 10) Làm sạch và chạy lại từ đầu

Khuyến nghị dùng script chung để dọn môi trường nhanh:

```bash
cd "${FABRIC_HOME}"
./scripts/clean-reset.sh
```

Nếu cần dọn sạch cả ledger volume + channel artifacts:

```bash
cd "${FABRIC_HOME}"
./scripts/clean-reset.sh --all --yes
```

Lệnh thủ công tương đương:

```bash
cd "${FABRIC_HOME}"
docker compose --env-file config/.env.network -f config/docker-compose-network.yaml down
docker compose -f config/docker-compose-ca.yaml down
```

Nếu cần reset volume ledger:

```bash
docker volume rm \
  config_orderer1.example.com \
  config_orderer2.example.com \
  config_orderer3.example.com \
  config_peer0.org1.example.com \
  config_peer1.org1.example.com \
  config_peer0.org2.example.com \
  config_peer1.org2.example.com
```

### 10.1 Clean run khuyến nghị trước khi test lại end-to-end

Khi bạn vừa đổi cấu hình hoặc đã chạy thử nhiều lần, nên chạy clean đầy đủ để tránh lỗi trạng thái cũ (ví dụ: orphan container, channel đã tồn tại, ledger lệch trạng thái).

```bash
cd "${FABRIC_HOME}"

# 1) Dọn toàn bộ trạng thái cũ (stack + volume + artifacts)
./scripts/clean-reset.sh --all --yes

# 2) Chạy lại flow triển khai
docker compose -f config/docker-compose-ca.yaml up -d
fca './scripts/enroll-org.sh org1 org1.example.com 7054 ca-org1'
fca './scripts/enroll-org.sh org2 org2.example.com 8054 ca-org2'
fca './scripts/enroll-org.sh orderer example.com 9054 ca-orderer'
docker compose --env-file config/.env.network -f config/docker-compose-network.yaml up -d
ftools 'export FABRIC_CFG_PATH=/workspace/config; ./scripts/setup_channel.sh'
```

Nếu bạn dùng `MODE A` (host binary), thay 3 lệnh `fca`/`ftools` ở trên bằng lệnh chạy script trực tiếp tương ứng.

### 10.2 Smoke test nhanh bằng MODE B sau khi clean run

Sau khi chạy xong mục `10.1`, dùng bộ lệnh dưới để xác nhận mạng đã hoạt động đúng:

```bash
cd "${FABRIC_HOME}"

# 1) Kiểm tra channel đã có trên orderer1
ftools 'osnadmin channel list -o localhost:9443 --ca-file organizations/ordererOrganizations/example.com/orderers/orderer1.example.com/tls/ca.crt --client-cert organizations/ordererOrganizations/example.com/users/Admin@example.com/tls/client.crt --client-key organizations/ordererOrganizations/example.com/users/Admin@example.com/tls/client.key'

# 2) Kiểm tra peer0 Org1 đã join channel
ftools 'export FABRIC_CFG_PATH=/workspace/config; export CORE_PEER_TLS_ENABLED=true; export CORE_PEER_LOCALMSPID=Org1MSP; export CORE_PEER_MSPCONFIGPATH=/workspace/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp; export CORE_PEER_ADDRESS=localhost:7051; export CORE_PEER_TLS_ROOTCERT_FILE=/workspace/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt; peer channel getinfo -c mychannel'

# 3) Kiểm tra peer0 Org2 đã join channel
ftools 'export FABRIC_CFG_PATH=/workspace/config; export CORE_PEER_TLS_ENABLED=true; export CORE_PEER_LOCALMSPID=Org2MSP; export CORE_PEER_MSPCONFIGPATH=/workspace/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp; export CORE_PEER_ADDRESS=localhost:9051; export CORE_PEER_TLS_ROOTCERT_FILE=/workspace/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt; peer channel getinfo -c mychannel'
```

Kỳ vọng pass:
- Lệnh `osnadmin channel list` có `mychannel`.
- 2 lệnh `peer channel getinfo` trả về `Blockchain info` với `height >= 1`.

## 11) Troubleshooting nhanh

- Fail ở bước CA: `docker compose -f config/docker-compose-ca.yaml logs -f`
- Fail ở enroll: kiểm tra file `tls-cert.pem` trong `organizations/fabric-ca/...`
- Fail ở setup channel: kiểm tra `FABRIC_CFG_PATH`, cert admin orderer, trạng thái orderer
- Fail ở peer `getinfo`: kiểm tra đúng context `CORE_PEER_*`

