#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "${ROOT_DIR}/scripts/enroll-org.sh"
bash -n "${ROOT_DIR}/scripts/clean-reset.sh"
bash -n "${ROOT_DIR}/scripts/update-anchor-peers.sh"
bash -n "${ROOT_DIR}/scripts/setup_channel.sh"

docker compose -f "${ROOT_DIR}/config/docker-compose-ca.yaml" config >/dev/null
docker compose -f "${ROOT_DIR}/config/docker-compose-network.yaml" --env-file "${ROOT_DIR}/config/.env.network" config >/dev/null

python - <<'PY'
from pathlib import Path
import yaml
for p in [
    Path('/home/tuyenngduc/workspaces/fabric/config/configtx.yaml'),
    Path('/home/tuyenngduc/workspaces/fabric/config/docker-compose-ca.yaml'),
    Path('/home/tuyenngduc/workspaces/fabric/config/docker-compose-network.yaml'),
]:
    yaml.safe_load(p.read_text())
print('YAML parse checks passed')
PY

echo "Validation complete"

