#!/usr/bin/env bash
# Restores vault (VMID 100) latest snapshot to test VMID 300,
# verifies it reaches running state, then destroys it.
set -euo pipefail
source "$(dirname "$0")/../.env"

TEST_VMID=300
SOURCE_VMID=100
NODE="pvehost"
PBS_STORAGE="pbs-lxc"
AUTH="Authorization: PVEAPIToken=$PROXMOX_USER!$PROXMOX_TOKEN_ID=$PROXMOX_TOKEN_SECRET"
BASE="https://$PROXMOX_HOST:8006/api2/json"

SNAPSHOT=$(curl -sk -H "$AUTH" "$BASE/nodes/$NODE/storage/$PBS_STORAGE/content" \
  | python3 -c "
import sys,json
items=[i for i in json.load(sys.stdin)['data'] if i.get('vmid')==$SOURCE_VMID]
items.sort(key=lambda x: x.get('ctime',0), reverse=True)
print(items[0]['volid'] if items else '')
")

[ -z "$SNAPSHOT" ] && { echo "ERROR: No backup found for VMID $SOURCE_VMID"; exit 1; }
echo "Restoring $SNAPSHOT to VMID $TEST_VMID..."

curl -sk -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"ostemplate\":\"$SNAPSHOT\",\"vmid\":$TEST_VMID,\"storage\":\"disks\",\"start\":1,\"unprivileged\":1}" \
  "$BASE/nodes/$NODE/lxc" > /dev/null

echo "Waiting 30s for boot..."
sleep 30

STATUS=$(curl -sk -H "$AUTH" "$BASE/nodes/$NODE/lxc/$TEST_VMID/status/current" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['status'])")
echo "VMID $TEST_VMID status: $STATUS"

curl -sk -X POST -H "$AUTH" "$BASE/nodes/$NODE/lxc/$TEST_VMID/status/stop" > /dev/null
sleep 5
curl -sk -X DELETE -H "$AUTH" "$BASE/nodes/$NODE/lxc/$TEST_VMID?purge=1" > /dev/null

[ "$STATUS" = "running" ] \
  && echo "✓ RESTORE TEST PASSED" \
  || { echo "✗ RESTORE TEST FAILED — VMID $TEST_VMID did not reach running state"; exit 1; }
