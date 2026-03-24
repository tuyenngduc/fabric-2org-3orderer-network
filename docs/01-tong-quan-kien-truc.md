# 01 - Tổng quan dự án và ý nghĩa từng thành phần

Tài liệu này mô tả kiến trúc tổng thể của mạng Hyperledger Fabric trong workspace hiện tại, giải thích vai trò từng thành phần, cách chúng liên kết với nhau, và các lưu ý khi chuyển sang production thực tế.

## 1) Phạm vi dự án

Mạng hiện tại đang theo mô hình:

- 2 tổ chức peer: `Org1MSP`, `Org2MSP`
- 3 orderer dùng EtcdRaft: `orderer1`, `orderer2`, `orderer3`
- 2 peer cho mỗi org (tổng 4 peer)
- 1 CouchDB cho mỗi peer (tổng 4 CouchDB)
- 3 Fabric CA (Org1, Org2, Orderer)


## 2) Kiến trúc logic

Luồng chính của hệ thống:

1. CA cấp danh tính và certificate
2. Script enroll tạo MSP/TLS cho org/peer/orderer
3. Docker Compose khởi động orderer/peer/couchdb
4. Script setup tạo channel, join node, cập nhật anchor peer
5. Triển khai chaincode theo Fabric lifecycle

Quan hệ thành phần:

- CA -> cấp cert cho Peer/Orderer/Admin
- `configtx.yaml` -> định nghĩa chính sách và topology channel/orderer
- Orderer cluster -> đồng thuận Raft và phân phối block
- Peer -> lưu ledger, xác thực giao dịch, chạy chaincode
- CouchDB -> state database cho peer

## 3) Ý nghĩa từng thành phần

### 3.1 Certificate Authority (CA)

Trong Hyperledger Fabric, mọi node và người dùng đều cần danh tính số (X.509). CA là nơi cấp và quản lý danh tính đó.
CA chịu trách nhiệm:

- Cấp cert cho peer, orderer, admin, client
- Xác thực danh tính khi enroll
- Cung cấp trust chain để TLS/MSP xác thực lẫn nhau

Nếu CA lỗi hoặc cấp cert sai, node có thể không bắt tay TLS được, admin không thao tác được, hoặc giao dịch bị từ chối vì sai danh tính. Trong dự án này, CA được triển khai như sau:

- File cấu hình: `config/docker-compose-ca.yaml`
- 3 CA riêng:
  - `ca_org1`
  - `ca_org2`
  - `ca_orderer`
- Dữ liệu CA nằm tại `organizations/fabric-ca/...`
- Script enroll dùng CA để tạo crypto materials: `scripts/enroll-org.sh`

### 3.2 MSP và danh tính tổ chức

MSP (Membership Service Provider) là lớp xác định **ai là thành viên hợp lệ** của một tổ chức và có **quyền gì**.
Nói cách khác, MSP là nền tảng của authorization trong Fabric:

- Xác định node/user thuộc org nào
- Phân vai trò (admin, peer, client, orderer)
- Là đầu vào cho mọi policy (Readers/Writers/Admins/Endorsement)

Trong dự án này, MSP được ánh xạ vào cấu hình và thư mục như sau:

- Khai báo MSP ở `config/configtx.yaml` trong phần `Organizations`
- Đường dẫn MSP root:
  - `organizations/peerOrganizations/org1.example.com/msp`
  - `organizations/peerOrganizations/org2.example.com/msp`
  - `organizations/ordererOrganizations/example.com/msp`
- NodeOUs được tạo trong quá trình enroll bởi `scripts/enroll-org.sh`

### 3.3 Orderer service và cơ chế đồng thuận Raft

Orderer là thành phần sắp xếp transaction theo thứ tự toàn cục và cắt block để phát cho peer.
Orderer **không chạy chaincode business logic**; nhiệm vụ chính là ordering + block distribution.

Với EtcdRaft:

- Cần cụm nhiều orderer để có leader và quorum
- Khi mất quorum, không tạo block mới được
- Khi đủ quorum, channel vẫn tiếp tục hoạt động dù mất 1 node

Trong dự án này, lớp orderer được cấu hình và triển khai như sau:

- Cấu hình Raft ở `config/configtx.yaml` phần `Orderer.EtcdRaft.Consenters`
- Runtime orderer ở `config/docker-compose-network.yaml`:
  - `orderer1.example.com`
  - `orderer2.example.com`
  - `orderer3.example.com`
- Join channel dùng channel participation API (`osnadmin`) trong `scripts/setup_channel.sh`

### 3.4 Peer node

Peer là nơi thực thi nghiệp vụ blockchain:

- Nhận proposal và thực hiện mô phỏng chaincode (endorsement)
- Commit block nhận từ orderer
- Lưu ledger cục bộ
- Cung cấp truy vấn trạng thái

Peer là nơi gần business logic nhất trong Fabric. Trong dự án này, peer được triển khai như sau:

- Runtime peer ở `config/docker-compose-network.yaml`
- 4 peer:
  - `peer0.org1.example.com`
  - `peer1.org1.example.com`
  - `peer0.org2.example.com`
  - `peer1.org2.example.com`
- MSP/TLS map từ `organizations/peerOrganizations/...`
- Join channel được tự động hóa trong `scripts/setup_channel.sh`

### 3.5 Ledger và state database (CouchDB)

Fabric có 2 lớp dữ liệu:

1. **Blockchain log**: chuỗi block bất biến
2. **World state**: trạng thái mới nhất của key-value

CouchDB là backend world state, hỗ trợ rich query JSON cho chaincode ứng dụng. Trong dự án này:

- Mỗi peer dùng một CouchDB riêng (4 peer = 4 CouchDB)
- Cấu hình trong `config/docker-compose-network.yaml`:
  - `CORE_LEDGER_STATE_STATEDATABASE=CouchDB`
  - `CORE_LEDGER_STATE_COUCHDBCONFIG_*`
- Thông số user/password tách qua `config/.env.network`

### 3.6 Channel, policy và governance

Channel là sổ cái logic riêng cho một nhóm tổ chức.
Mỗi channel có:

- Thành viên tham gia
- Bộ policy quản trị/vận hành
- Cấu hình orderer/consensus

Policy quyết định ai được đọc/ghi, ai được cập nhật cấu hình, và quy tắc endorsement của giao dịch. Trong dự án này:

- Channel profile: `TwoOrgsApplicationGenesis` trong `config/configtx.yaml`
- Script tạo channel + join nodes: `scripts/setup_channel.sh`
- Cập nhật anchor peer theo luồng production-safe: `scripts/update-anchor-peers.sh`

### 3.7 Lớp runtime orchestration (Compose + env + scripts)

Trong môi trường thực tế, thành công của vận hành không chỉ nằm ở topology, mà còn ở khả năng tái lập quy trình và giảm sai sót thao tác tay.

Trong dự án này, lớp orchestration được tổ chức như sau:

- `config/docker-compose-network.yaml`: định nghĩa runtime services
- `config/.env.network`: gom biến môi trường vận hành
- `scripts/validate-stack.sh`: pre-flight check
- `scripts/backup-ledger.sh`: backup dữ liệu ledger theo volume

## 4) Ý nghĩa từng file cấu hình chính

### 4.1 `config/docker-compose-ca.yaml`

Vai trò: chạy 3 CA server dùng để cấp chứng chỉ và danh tính.

Chứa các nhóm cấu hình quan trọng:

- Tên CA (`FABRIC_CA_SERVER_CA_NAME`)
- Cổng public (`7054`, `8054`, `9054`)
- TLS CA server (`FABRIC_CA_SERVER_TLS_ENABLED=true`)
- Thư mục dữ liệu CA qua volume bind

Ý nghĩa thực tế:

- Nếu CA không chạy, mọi bước enroll sẽ fail
- Dữ liệu CA trong `organizations/fabric-ca/...` cần được backup

### 4.2 `config/configtx.yaml`

Vai trò: "luật chơi" của mạng/channel.

Nội dung chính:

- Định nghĩa `Organizations` (`OrdererMSP`, `Org1MSP`, `Org2MSP`)
- Định nghĩa `OrdererType: etcdraft` và danh sách consenters
- Chính sách kênh (`Readers`, `Writers`, `Admins`, `Endorsement`)
- Profile `TwoOrgsApplicationGenesis`

Ý nghĩa thực tế:

- Sai MSP ID, sai cert path, sai consenter port => channel không hoạt động đúng
- Đây là file quan trọng nhất cho governance

### 4.3 `config/docker-compose-network.yaml`

Vai trò: chạy runtime services của mạng.

Bao gồm:

- 3 orderer containers
- 4 peer containers
- 4 couchdb containers
- Volume map MSP/TLS vào từng container
- Cấu hình TLS, healthcheck, restart policy, resource limits

Ý nghĩa thực tế:

- Sai map đường dẫn MSP/TLS => container restart loop
- Sai port nội bộ orderer => Raft không bầu leader được

### 4.4 `config/.env.network` và `config/.env.network.example`

Vai trò: tập trung biến môi trường runtime.

Hiện dùng cho:

- `FABRIC_LOGGING_SPEC`
- `COUCHDB_USER`
- `COUCHDB_PASSWORD`

Ý nghĩa thực tế:

- Dễ đổi cấu hình giữa môi trường dev/staging/prod
- Cần tách secret ra Vault/KMS ở production

## 5) Cấu trúc thư mục

```text
fabric/
  config/
  organizations/
    fabric-ca/
    peerOrganizations/
    ordererOrganizations/
  channel-artifacts/
  scripts/
  docs/
```

Ý nghĩa:

- `organizations/` là nơi chứa crypto materials
- `channel-artifacts/` là nơi chứa block/tx artifacts
- `docs/` là tài liệu vận hành/triển khai

## 6) Mapping service và port

### CA

- `ca_org1`: `7054`
- `ca_org2`: `8054`
- `ca_orderer`: `9054`

### Orderer

- `orderer1.example.com`: orderer `7050`, admin `9443`
- `orderer2.example.com`: orderer `8050`, admin `10443`
- `orderer3.example.com`: orderer `9050`, admin `11443`

### Peer

- Org1: `7051`, `8051`
- Org2: `9051`, `10051`

### CouchDB

- Org1: `5984`, `6984`
- Org2: `7984`, `8984`

## 7) Lưu ý production thực tế

Hiện trạng là production-style baseline. Để production thực chiến cần thêm:

- Bỏ bootstrap credential mặc định `admin/adminpw`
- Dùng secret manager (Vault/KMS), không để secret trực tiếp trong file
- Kế hoạch rotate cert và kiểm thử định kỳ
- Monitoring/alerting tập trung (Prometheus/Grafana/Alertmanager)
- Runbook DR (backup/restore/failover) có diễn tập
- Tách node thật theo fault domain thay vì chỉ 1 máy cục bộ

## 8) Tài liệu liên quan

- `docs/02-quy-trinh-trien-khai-fabric.vi.md`
- `docs/03-van-hanh-su-co-va-test-fabric.vi.md`
