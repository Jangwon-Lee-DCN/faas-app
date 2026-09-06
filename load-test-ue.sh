#!/bin/bash

# load-test-ue.sh
# Run this script inside the UE pod.
# This mode forces curl to use uesimtun0, so traffic goes through:
# UE -> gNB -> UPF -> Kourier NodePort -> image-classifier

IMAGE="test_0_cat.png"
N="${1:-5}"

IP="${2:-172.31.81.11}"
PORT="${3:-30980}"
URL="http://$IP:$PORT/predict"
HOST="image-classifier.default.$IP.sslip.io"
UE_IFACE="uesimtun0"

if ! ip link show "$UE_IFACE" >/dev/null 2>&1; then
  echo "[ERROR] Interface $UE_IFACE not found."
  echo "        Check whether UE registration and PDU session are established."
  exit 1
fi

if [ ! -f "$IMAGE" ]; then
  echo "[ERROR] Image file not found: $IMAGE"
  exit 1
fi

send_request() {
  local ID=$1
  local T0
  local T1
  local LAT
  local RESPONSE
  local EXIT
  local META
  local BODY

  T0=$(date +%s%N)

  RESPONSE=$(curl -sS -w "\nHTTP_CODE=%{http_code} LOCAL_IP=%{local_ip} REMOTE_IP=%{remote_ip} TOTAL_TIME=%{time_total}" \
    --interface "$UE_IFACE" \
    -H "Host: $HOST" \
    -F "file=@$IMAGE" \
    "$URL" 2>&1)

  EXIT=$?
  T1=$(date +%s%N)
  LAT=$(awk "BEGIN {printf \"%.3f\", ($T1 - $T0) / 1000000}")

  META=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  if [ $EXIT -ne 0 ]; then
    echo "[req $ID] CURL_ERROR exit=$EXIT latency=${LAT}ms msg=$RESPONSE"
  else
    echo "[req $ID] latency=${LAT}ms $META body=$BODY"
  fi
}

T_BATCH=$(date +%s%N)

echo "────────────────────────────"
echo "Mode       : UE"
echo "URL        : $URL"
echo "Host       : $HOST"
echo "Image      : $IMAGE"
echo "Concurrency: $N"
echo "Interface  : $UE_IFACE"
echo "Path       : 5G user plane"
echo "────────────────────────────"

for i in $(seq 1 "$N"); do
  send_request "$i" &
done

wait

T_END=$(date +%s%N)
TOTAL=$(awk "BEGIN {printf \"%.3f\", ($T_END - $T_BATCH) / 1000000}")

echo "────────────────────────────"
echo "wall-clock: $TOTAL ms  ($N requests)"