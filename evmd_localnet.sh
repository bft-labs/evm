#!/usr/bin/env bash
set -euo pipefail

# Simple multi-node localnet launcher for evmd
# - Initializes N validator nodes under BASE_DIR using `evmd testnet init-files --single-host`
# - Optionally computes persistent_peers via `evmd comet show-node-id` if available
# - Starts each node with its own home and port set by init-files
#
# Usage:
#   scripts/evmd-localnet.sh start   # init (if needed) and start N nodes
#   scripts/evmd-localnet.sh stop    # stop nodes started by this script (via PID file)
#   scripts/evmd-localnet.sh clean   # remove BASE_DIR

BINARY_DEFAULT="evmd"                 # or override via BINARY env
BASE_DIR_DEFAULT="./.testnets"        # or override via BASE_DIR env
NODE_PREFIX_DEFAULT="node"
N_DEFAULT=4
# Align with local_node.sh default CHAINID (9001)
CHAIN_ID_DEFAULT="9001"
MIN_GAS_PRICES_DEFAULT="0atest"

# Derive settings from env or defaults
BINARY=${BINARY:-$BINARY_DEFAULT}
BASE_DIR=${BASE_DIR:-$BASE_DIR_DEFAULT}
NODE_PREFIX=${NODE_PREFIX:-$NODE_PREFIX_DEFAULT}
N=${N:-$N_DEFAULT}
CHAIN_ID=${CHAIN_ID:-$CHAIN_ID_DEFAULT}
MIN_GAS_PRICES=${MIN_GAS_PRICES:-$MIN_GAS_PRICES_DEFAULT}

# Internal
PID_FILE="${BASE_DIR}/evmd_localnet.pids"

log() { echo "[evmd-localnet] $*"; }
err() { echo "[evmd-localnet:ERROR] $*" >&2; }

ensure_binary() {
  if command -v "$BINARY" >/dev/null 2>&1; then
    return 0
  fi
  # Fallback to local build path
  if [ -x "./build/evmd" ]; then
    BINARY="./build/evmd"
    return 0
  fi
  err "Cannot find evmd binary. Put it on PATH or build via 'make build'."
  exit 1
}

init_if_needed() {
  local first_home_dir="${BASE_DIR}/${NODE_PREFIX}0/evmd"
  local genesis_file="${first_home_dir}/config/genesis.json"
  if [ -f "$genesis_file" ]; then
    # If an existing genesis is present, verify its chain_id matches desired CHAIN_ID.
    local existing_chain_id
    if command -v jq >/dev/null 2>&1; then
      existing_chain_id=$(jq -r '.chain_id' "$genesis_file" 2>/dev/null || true)
    fi
    if [ -z "${existing_chain_id:-}" ]; then
      # Fallback parser if jq is unavailable
      existing_chain_id=$(sed -n 's/.*"chain_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$genesis_file" | head -n1)
    fi

    if [ -n "$existing_chain_id" ] && [ "$existing_chain_id" != "$CHAIN_ID" ]; then
      log "Existing testnet has chain-id '$existing_chain_id' but requested '$CHAIN_ID'. Re-initializing…"
      rm -rf "$BASE_DIR"
    else
      log "Existing testnet detected at ${BASE_DIR} (chain-id: ${existing_chain_id:-unknown}); skipping init-files."
      return 0
    fi
  fi

  log "Initializing ${N}-node testnet at ${BASE_DIR} (single host ports)…"
  mkdir -p "$BASE_DIR"

  # --single-host ensures distinct ports per node on one machine
  "$BINARY" testnet init-files \
    --validator-count "${N}" \
    --output-dir "${BASE_DIR}" \
    --single-host \
    --keyring-backend test \
    --chain-id "${CHAIN_ID}"

  log "Init complete. Genesis and configs written under ${BASE_DIR}/${NODE_PREFIX}{0..$((N-1))}/evmd"
}

build_peers_if_possible() {
  # Try to gather node IDs using `evmd comet show-node-id` if the subcommand exists.
  if ! "$BINARY" comet --help >/dev/null 2>&1; then
    log "'evmd comet' subcommand not found. Skipping persistent_peers injection (nodes should still connect with generated configs)."
    return 0
  fi

  local peers=""
  for ((i=0; i< N; i++)); do
    local home_dir="${BASE_DIR}/${NODE_PREFIX}${i}/evmd"
    local id
    if ! id=$("$BINARY" comet show-node-id --home "$home_dir" 2>/dev/null); then
      err "Failed to read node ID for ${NODE_PREFIX}${i}; skipping persistent_peers."
      return 0
    fi
    # Ports per init-files when --single-host is used:
    # - P2P starts at 16656 and increments by +1 per node
    local p2p_port=$((16656 + i))
    local entry="${id}@127.0.0.1:${p2p_port}"
    if [ -z "$peers" ]; then peers="$entry"; else peers+="",$entry; fi
  done

  log "persistent_peers=${peers}"
  # Inject into each node's config.toml
  for ((i=0; i< N; i++)); do
    local cfg="${BASE_DIR}/${NODE_PREFIX}${i}/evmd/config/config.toml"
    if [ -f "$cfg" ]; then
      # Replace existing line or append if missing
      if grep -q '^persistent_peers\s*=\s*"' "$cfg"; then
        sed -i.bak -E "s|^persistent_peers\s*=\s*\".*\"|persistent_peers = \"${peers}\"|" "$cfg"
      else
        echo "persistent_peers = \"${peers}\"" >> "$cfg"
      fi
    fi
  done
}

start_nodes() {
  mkdir -p "$(dirname "$PID_FILE")"
  : > "$PID_FILE"

  for ((i=0; i< N; i++)); do
    local home_dir="${BASE_DIR}/${NODE_PREFIX}${i}/evmd"
    local log_file="${home_dir}/evmd.log"

    # Compute display ports that init-files configure for single-host:
    local rpc_port=$((26657 + i))
    local p2p_port=$((16656 + i))
    local api_port=$((1317 + i))
    local http_port=$((8545 + i*10))
    local ws_port=$((8546 + i*10))

    log "Starting ${NODE_PREFIX}${i} (rpc:${rpc_port}, p2p:${p2p_port}, api:${api_port}, http:${http_port}, ws:${ws_port})"

    # Build start command (aligned with local_node.sh defaults) and echo it for reproducibility
    cmd=("$BINARY" start \
      --home "$home_dir" \
      --minimum-gas-prices "${MIN_GAS_PRICES}" \
      --evm.min-tip 0 \
      --json-rpc.api "eth,txpool,personal,net,debug,web3" \
      --chain-id "${CHAIN_ID}")

    printf '[evmd-localnet] Exec: '
    for arg in "${cmd[@]}"; do printf '%s ' "$arg"; done; printf '\n'

    # Start in background, capture PID
    ("${cmd[@]}" >"$log_file" 2>&1 & echo $! >> "$PID_FILE")
    sleep 0.5
  done

  log "All nodes started. PIDs recorded in ${PID_FILE}"
}

stop_nodes() {
  if [ ! -f "$PID_FILE" ]; then
    err "PID file not found: $PID_FILE"
    exit 1
  fi
  tac "$PID_FILE" | while read -r pid; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      log "Stopping PID $pid"
      kill "$pid" || true
    fi
  done
  rm -f "$PID_FILE"
  log "All nodes stopped."
}

clean() {
  if [ -d "$BASE_DIR" ]; then
    log "Removing ${BASE_DIR}"
    rm -rf "$BASE_DIR"
  fi
}

cmd=${1:-start}
case "$cmd" in
  start)
    ensure_binary
    init_if_needed
    build_peers_if_possible
    start_nodes
    ;;
  stop)
    stop_nodes
    ;;
  clean)
    clean
    ;;
  *)
    echo "Usage: $0 {start|stop|clean}" >&2
    exit 1
    ;;
esac
