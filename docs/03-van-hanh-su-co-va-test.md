# 03 - Vận hành hằng ngày, xử lý sự cố và hướng dẫn test chi tiết

Tài liệu này tập trung vào vận hành sau khi mạng đã triển khai: thao tác hằng ngày, debug sự cố phổ biến, và checklist test chi tiết để xác nhận mạng hoạt động ổn định.

Thiết lập biến môi trường dùng chung trước khi chạy lệnh:

```bash
export FABRIC_HOME="/path/to/fabric"
cd "${FABRIC_HOME}"
```

Nếu máy chưa cài đầy đủ CLI Fabric trên host, dùng container CLI:

```bash
alias ftools='docker run --rm --network host -v "${FABRIC_HOME}":/workspace -w /workspace hyperledger/fabric-tools:2.5 bash -lc'
```

## 1) Luồng vận hành hằng ngày

## 1.1 Khởi động hệ thống

```bash
cd "${FABRIC_HOME}"
docker compose -f config/docker-compose-ca.yaml up -d
docker compose --env-file config/.env.network -f config/docker-compose-network.yaml up -d
```

## 1.2 Dừng hệ thống

```bash
cd "${FABRIC_HOME}"
docker compose --env-file config/.env.network -f config/docker-compose-network.yaml down
docker compose -f config/docker-compose-ca.yaml down
```

## 1.3 Xem trạng thái nhanh

```bash
cd "${FABRIC_HOME}"
docker compose -f config/docker-compose-ca.yaml ps
docker compose --env-file config/.env.network -f config/docker-compose-network.yaml ps
```

## 1.4 Xem log theo thành phần

```bash
cd "${FABRIC_HOME}"
docker compose --env-file config/.env.network -f config/docker-compose-network.yaml logs -f orderer1.example.com
docker compose --env-file config/.env.network -f config/docker-compose-network.yaml logs -f peer0.org1.example.com
docker compose --env-file config/.env.network -f config/docker-compose-network.yaml logs -f couchdb0.org1
```

## 1.5 Backup định kỳ

```bash
cd "${FABRIC_HOME}"
./scripts/backup-ledger.sh
```

Tuỳ chỉnh thư mục backup:

```bash
BACKUP_DIR="${FABRIC_HOME}/backups" ./scripts/backup-ledger.sh
```

## 2) Quy trình kiểm tra sức khỏe (health runbook)

Mỗi ngày/ca trực nên chạy:

1. `docker compose ps` để kiểm tra trạng thái `Up/healthy`
2. Kiểm tra channel tồn tại trên orderer
3. Kiểm tra `peer channel getinfo` trên peer đại diện mỗi org
4. Kiểm tra dung lượng ổ đĩa chứa volume
5. Kiểm tra backup mới nhất có được tạo

### 2.1 Kiểm tra channel ở orderer

```bash
cd "${FABRIC_HOME}"
ftools 'osnadmin channel list -o localhost:9443 --ca-file organizations/ordererOrganizations/example.com/orderers/orderer1.example.com/tls/ca.crt --client-cert organizations/ordererOrganizations/example.com/users/Admin@example.com/tls/client.crt --client-key organizations/ordererOrganizations/example.com/users/Admin@example.com/tls/client.key'
```

### 2.2 Kiểm tra block height ở peer

```bash
cd "${FABRIC_HOME}"
ftools 'export FABRIC_CFG_PATH=/workspace/config; export CORE_PEER_TLS_ENABLED=true; export CORE_PEER_LOCALMSPID=Org1MSP; export CORE_PEER_MSPCONFIGPATH=/workspace/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp; export CORE_PEER_ADDRESS=localhost:7051; export CORE_PEER_TLS_ROOTCERT_FILE=/workspace/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt; peer channel getinfo -c mychannel'
```

## 3) Các lỗi thường gặp và cách xử lý

## 3.1 Lỗi thiếu file cert/MSP

Triệu chứng:

- Container restart liên tục
- Script báo thiếu `tls/ca.crt`, `server.crt`, `msp`

Cách xử lý:

1. Kiểm tra lại output của `scripts/enroll-org.sh`
2. So sánh đường dẫn volume trong `config/docker-compose-network.yaml`
3. Enroll lại org tương ứng
4. Restart service

## 3.2 Lỗi `Config File "core" Not Found`

Triệu chứng:

- `peer` CLI fail khi chạy `setup_channel.sh` hoặc lệnh tay

Nguyên nhân:

- `FABRIC_CFG_PATH` không trỏ tới nơi có `core.yaml`

Cách xử lý:

```bash
cd "${FABRIC_HOME}"
export FABRIC_CFG_PATH="${FABRIC_HOME}/config"
```

## 3.3 Lỗi `osnadmin` TLS handshake / connection refused

Triệu chứng:

- `osnadmin channel join/list` fail TLS

Nguyên nhân thường gặp:

- Sai `client.crt/client.key`
- Sai `--ca-file`
- Orderer admin endpoint chưa lên

Cách xử lý:

1. Kiểm tra `docker compose ps`
2. Kiểm tra file trong `organizations/ordererOrganizations/example.com/users/Admin@example.com/tls/`
3. Test endpoint bằng `osnadmin channel list`

Nếu đang dùng container CLI, chạy qua `ftools` thay vì gọi trực tiếp `osnadmin` trên host.

## 3.4 Lỗi Raft không bầu được leader

Triệu chứng:

- Log orderer lặp `pre-candidate` hoặc `connection refused` giữa consenters

Nguyên nhân:

- Sai listen port nội bộ orderer so với `configtx.yaml`
- Port mapping/container config không đồng nhất

Cách xử lý:

1. So khớp lại `config/configtx.yaml` và `config/docker-compose-network.yaml`
2. Restart stack sạch + reset volume runtime nếu cần

## 3.5 Lỗi update anchor peer (version mismatch)

Triệu chứng:

- Cập nhật anchor báo mismatch version khi dùng tx tĩnh

Giải pháp hiện tại:

- Dùng `scripts/update-anchor-peers.sh` (fetch config + compute update)
- Script đã hỗ trợ no-op nếu anchor đã đúng

## 4) Hướng dẫn test chi tiết

## 4.1 Test cấp 1 - Smoke test triển khai

Mục tiêu: xác nhận stack lên được và channel hoạt động.

Checklist:

- [ ] CA services `Up`
- [ ] Runtime services `Up/healthy`
- [ ] `mychannel` có trong `osnadmin channel list`
- [ ] `peer channel getinfo` trả `height >= 1` trên 4 peer

Lệnh gợi ý:

```bash
cd "${FABRIC_HOME}"
./scripts/validate-stack.sh
./scripts/setup_channel.sh
```

Nếu dùng container CLI cho bước setup channel:

```bash
cd "${FABRIC_HOME}"
ftools 'export FABRIC_CFG_PATH=/workspace/config; ./scripts/setup_channel.sh'
```

## 4.2 Test cấp 2 - Test idempotency

Mục tiêu: chạy lại script không phá trạng thái đang có.

Checklist:

- [ ] Chạy lại `enroll-org.sh` không fail cứng
- [ ] Chạy lại `setup_channel.sh` không fail (join đã tồn tại thì skip)
- [ ] `update-anchor-peers.sh` báo no-op khi không có thay đổi

## 4.3 Test cấp 3 - Test phục hồi (backup/restore mini)

Mục tiêu: xác minh có thể backup dữ liệu ledger.

Bước test:

1. Chạy backup script
2. Kiểm tra file `.tar.gz` được tạo
3. Ghi nhận timestamp/size

```bash
cd "${FABRIC_HOME}"
./scripts/backup-ledger.sh
ls -lh backups/
```

## 4.4 Test cấp 4 - Test thao tác CLI chuẩn

Mục tiêu: xác nhận context CLI đúng cho từng org.

Ví dụ Org1 peer0:

```bash
cd "${FABRIC_HOME}"
ftools 'export FABRIC_CFG_PATH=/workspace/config; export CORE_PEER_LOCALMSPID=Org1MSP; export CORE_PEER_MSPCONFIGPATH=/workspace/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp; export CORE_PEER_ADDRESS=localhost:7051; export CORE_PEER_TLS_ENABLED=true; export CORE_PEER_TLS_ROOTCERT_FILE=/workspace/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt; peer channel list'
```

## 4.5 Mẫu báo cáo test (khuyến nghị)

Nên ghi lại theo form:

- Mốc thời gian test
- Phiên bản binary và image
- Kết quả từng checklist (Pass/Fail)
- Log lỗi (nếu có)
- Hành động khắc phục đã thực hiện

## 5) Quick command sheet cho vận hành

```bash
# Validate nhanh
cd "${FABRIC_HOME}"
./scripts/validate-stack.sh

# Chạy lại setup channel
ftools 'export FABRIC_CFG_PATH=/workspace/config; ./scripts/setup_channel.sh'

# Xem trạng thái runtime

docker compose --env-file config/.env.network -f config/docker-compose-network.yaml ps

# Xem log orderer1

docker compose --env-file config/.env.network -f config/docker-compose-network.yaml logs -f orderer1.example.com
```


