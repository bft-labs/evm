#!/usr/bin/env bash
set -euo pipefail

# Simple multi-node localnet launcher for evmd
# - Initializes N validator nodes under BASE_DIR using `evmd testnet init-files --validator-count N --keyring-backend test`
# - Applies surge faucet to node0 genesis, then replicates the modified genesis to all nodes
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
# Start defaults (min gas aligned with local_node.sh)
MIN_GAS_PRICES_DEFAULT="0atest"
SURGE_CMD_DEFAULT="surge faucet"     # or override via SURGE_CMD env; extra args via SURGE_ARGS

# Derive settings from env or defaults
BINARY=${BINARY:-$BINARY_DEFAULT}
BASE_DIR=${BASE_DIR:-$BASE_DIR_DEFAULT}
NODE_PREFIX=${NODE_PREFIX:-$NODE_PREFIX_DEFAULT}
N=${N:-$N_DEFAULT}
MIN_GAS_PRICES=${MIN_GAS_PRICES:-$MIN_GAS_PRICES_DEFAULT}
SURGE_CMD=${SURGE_CMD:-$SURGE_CMD_DEFAULT}
SURGE_ARGS=${SURGE_ARGS:-}

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

init_fresh() {
  # Always initialize a fresh testnet as requested
  rm -rf "$BASE_DIR"
  log "Initializing ${N}-node testnet at ${BASE_DIR}…"
  mkdir -p "$BASE_DIR"

  # Per request: use only validator-count and keyring-backend flags (+ output-dir to control location)
  local cmd=("$BINARY" testnet init-files \
    --validator-count "${N}" \
    --keyring-backend test \
    --output-dir "${BASE_DIR}")

  printf '[evmd-localnet] Exec: '
  for a in "${cmd[@]}"; do printf '%s ' "$a"; done; printf '\n'
  "${cmd[@]}"

  log "Init complete. Genesis and configs under ${BASE_DIR}/${NODE_PREFIX}{0..$((N-1))}/evmd"
}

apply_surge_and_replicate() {
  # Apply surge faucet on node0 genesis, then copy to other nodes
  local g0="${BASE_DIR}/${NODE_PREFIX}0/evmd/config/genesis.json"
  if [ ! -f "$g0" ]; then
    err "node0 genesis not found at $g0"
    exit 1
  fi

  # Run surge faucet if available/desired
  if [ -n "$SURGE_CMD" ]; then
    local surge_bin
    surge_bin=$(echo "$SURGE_CMD" | awk '{print $1}')
    if ! command -v "$surge_bin" >/dev/null 2>&1; then
      err "'$surge_bin' not found on PATH. Set SURGE_CMD='' to skip or install surge."
      exit 1
    fi
    # Echo the exact command
    printf '[evmd-localnet] Exec: %s %s %s\n' "$SURGE_CMD" "${SURGE_ARGS}" "$g0"
    # Execute with optional extra args
    eval "$SURGE_CMD ${SURGE_ARGS} $g0"
  else
    log "SURGE_CMD empty; skipping surge faucet step."
  fi

  # Replicate node0 genesis to all other nodes
  for ((i=1; i< N; i++)); do
    local gi="${BASE_DIR}/${NODE_PREFIX}${i}/evmd/config/genesis.json"
    if [ -f "$gi" ]; then
      cp "$g0" "$gi"
    fi
  done

  # Validate genesis for all nodes (best-effort)
  for ((i=0; i< N; i++)); do
    local home_dir="${BASE_DIR}/${NODE_PREFIX}${i}/evmd"
    if [ -d "$home_dir" ]; then
      "$BINARY" genesis validate-genesis --home "$home_dir" >/dev/null 2>&1 || true
    fi
  done
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

    # Build start command (aligned with local_node.sh gas defaults) and echo it for reproducibility
    cmd=("$BINARY" start \
      --home "$home_dir" \
      --minimum-gas-prices "${MIN_GAS_PRICES}" \
      --evm.min-tip 0 \
      --json-rpc.api "eth,txpool,personal,net,debug,web3"
      --memlog)

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
    init_fresh
    apply_surge_and_replicate
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
