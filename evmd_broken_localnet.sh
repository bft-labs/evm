#!/usr/bin/env bash
set -euo pipefail

# Multi-node localnet launcher with mixed binaries (normal + consensus-breaking)
# - setup: Builds both normal and broken evmd binaries
# - start: Runs 3 normal nodes + 1 broken node
# - stop: Stops all nodes
# - clean: Removes all test data
#
# Usage:
#   ./evmd_localnet_mixed.sh setup   # Build both binaries
#   ./evmd_localnet_mixed.sh start   # Start 4 nodes (3 normal, 1 broken)
#   ./evmd_localnet_mixed.sh stop    # Stop all nodes
#   ./evmd_localnet_mixed.sh clean   # Remove .testnets directory

BASE_DIR_DEFAULT="./.testnets"
NODE_PREFIX_DEFAULT="node"
N_DEFAULT=4
MIN_GAS_PRICES_DEFAULT="0atest"
SURGE_CMD_DEFAULT="surge faucet"
CHAIN_ID_DEFAULT="local-4221"
SINGLE_HOST_DEFAULT="true"
STARTING_IP_DEFAULT="127.0.0.1"

# Cosmos SDK versions
COSMOS_SDK_NORMAL="github.com/bft-labs/cosmos-sdk v0.53.4-memlogger-4"
COSMOS_SDK_BROKEN="github.com/bft-labs/cosmos-sdk v0.53.4-memlogger-break-0"

# Derive settings from env or defaults
BASE_DIR=${BASE_DIR:-$BASE_DIR_DEFAULT}
NODE_PREFIX=${NODE_PREFIX:-$NODE_PREFIX_DEFAULT}
N=${N:-$N_DEFAULT}
MIN_GAS_PRICES=${MIN_GAS_PRICES:-$MIN_GAS_PRICES_DEFAULT}
SURGE_CMD=${SURGE_CMD:-$SURGE_CMD_DEFAULT}
SURGE_ARGS=${SURGE_ARGS:-}
CHAIN_ID=${CHAIN_ID:-$CHAIN_ID_DEFAULT}
SINGLE_HOST=${SINGLE_HOST:-$SINGLE_HOST_DEFAULT}
STARTING_IP_ADDRESS=${STARTING_IP_ADDRESS:-$STARTING_IP_DEFAULT}

# Binary paths
BUILDS_DIR="${BASE_DIR}/builds"
BINARY_NORMAL="${BUILDS_DIR}/evmd"
BINARY_BROKEN="${BUILDS_DIR}/broken_evmd"
BUILD_OUTPUT="./build/evmd"

# Internal
PID_FILE="${BASE_DIR}/evmd_localnet_mixed.pids"
GO_MOD_BACKUP="${BASE_DIR}/go.mod.backup"
EVMD_GO_MOD_BACKUP="${BASE_DIR}/evmd_go.mod.backup"

log() { echo "[evmd-localnet-mixed] $*"; }
err() { echo "[evmd-localnet-mixed:ERROR] $*" >&2; }

setup_binaries() {
  log "Setting up binaries in ${BUILDS_DIR}"
  mkdir -p "$BUILDS_DIR"
  mkdir -p "./build"

  # Backup original go.mod files if not already backed up
  if [ ! -f "$GO_MOD_BACKUP" ]; then
    log "Backing up go.mod"
    cp go.mod "$GO_MOD_BACKUP"
  fi
  if [ ! -f "$EVMD_GO_MOD_BACKUP" ]; then
    log "Backing up evmd/go.mod"
    cp evmd/go.mod "$EVMD_GO_MOD_BACKUP"
  fi

  # Build normal binary
  log "Building normal evmd binary (cosmos-sdk v0.53.4-memlogger-4)..."
  log "Updating go.mod files to use ${COSMOS_SDK_NORMAL}"
  sed -i '' "s|github.com/cosmos/cosmos-sdk => github.com/bft-labs/cosmos-sdk v0.53.4-memlogger-break-[0-9]*|github.com/cosmos/cosmos-sdk => ${COSMOS_SDK_NORMAL}|" go.mod
  sed -i '' "s|github.com/cosmos/cosmos-sdk => github.com/bft-labs/cosmos-sdk v0.53.4-memlogger-[0-9]*|github.com/cosmos/cosmos-sdk => ${COSMOS_SDK_NORMAL}|" go.mod
  sed -i '' "s|github.com/cosmos/cosmos-sdk => github.com/bft-labs/cosmos-sdk v0.53.4-memlogger-break-[0-9]*|github.com/cosmos/cosmos-sdk => ${COSMOS_SDK_NORMAL}|" evmd/go.mod
  sed -i '' "s|github.com/cosmos/cosmos-sdk => github.com/bft-labs/cosmos-sdk v0.53.4-memlogger-[0-9]*|github.com/cosmos/cosmos-sdk => ${COSMOS_SDK_NORMAL}|" evmd/go.mod

  log "Running go mod tidy in root..."
  go mod tidy
  log "Running go mod tidy in evmd/..."
  cd evmd && go mod tidy && cd ..

  log "Building normal binary with go build..."
  cd evmd && CGO_ENABLED="1" go build -tags "netgo" -ldflags '-w -s' -trimpath -o ../build/evmd ./cmd/evmd
  cd ..

  if [ ! -f "$BUILD_OUTPUT" ]; then
    err "Failed to build normal binary"
    exit 1
  fi
  cp "$BUILD_OUTPUT" "$BINARY_NORMAL"
  log "Normal binary saved to ${BINARY_NORMAL}"

  # Build broken binary with consensus_break tag
  log "Building broken evmd binary (cosmos-sdk v0.53.4-memlogger-break-0 + BUILD_TAGS=consensus_break)..."
  log "Updating go.mod files to use ${COSMOS_SDK_BROKEN}"
  sed -i '' "s|github.com/cosmos/cosmos-sdk => github.com/bft-labs/cosmos-sdk v0.53.4-memlogger-[0-9]*|github.com/cosmos/cosmos-sdk => ${COSMOS_SDK_BROKEN}|" go.mod
  sed -i '' "s|github.com/cosmos/cosmos-sdk => github.com/bft-labs/cosmos-sdk v0.53.4-memlogger-[0-9]*|github.com/cosmos/cosmos-sdk => ${COSMOS_SDK_BROKEN}|" evmd/go.mod

  log "Running go mod tidy in root..."
  go mod tidy
  log "Running go mod tidy in evmd/..."
  cd evmd && go mod tidy && cd ..

  log "Building broken binary with BUILD_TAGS=consensus_break..."
  cd evmd && CGO_ENABLED="1" go build -tags "netgo,consensus_break" -ldflags '-w -s' -trimpath -o ../build/evmd ./cmd/evmd
  cd ..

  if [ ! -f "$BUILD_OUTPUT" ]; then
    err "Failed to build broken binary"
    exit 1
  fi
  cp "$BUILD_OUTPUT" "$BINARY_BROKEN"
  log "Broken binary saved to ${BINARY_BROKEN}"

  # Restore original go.mod files
  log "Restoring original go.mod files"
  cp "$GO_MOD_BACKUP" go.mod
  cp "$EVMD_GO_MOD_BACKUP" evmd/go.mod

  log "Running go mod tidy to restore dependencies..."
  go mod tidy
  cd evmd && go mod tidy && cd ..

  # Verify both binaries exist
  if [ -f "$BINARY_NORMAL" ] && [ -f "$BINARY_BROKEN" ]; then
    log "Setup complete! Binaries ready:"
    log "  Normal: ${BINARY_NORMAL}"
    log "  Broken: ${BINARY_BROKEN}"
  else
    err "Binary setup failed"
    exit 1
  fi
}

verify_binaries() {
  if [ ! -f "$BINARY_NORMAL" ]; then
    err "Normal binary not found at ${BINARY_NORMAL}"
    err "Run './evmd_localnet_mixed.sh setup' first"
    exit 1
  fi
  if [ ! -f "$BINARY_BROKEN" ]; then
    err "Broken binary not found at ${BINARY_BROKEN}"
    err "Run './evmd_localnet_mixed.sh setup' first"
    exit 1
  fi
  log "Binaries verified: normal and broken evmd found"
}

init_fresh() {
  # Remove old testnet data (but preserve builds directory)
  for ((i=0; i<N; i++)); do
    local node_dir="${BASE_DIR}/${NODE_PREFIX}${i}"
    if [ -d "$node_dir" ]; then
      rm -rf "$node_dir"
    fi
  done
  [ -f "$PID_FILE" ] && rm -f "$PID_FILE"

  log "Initializing ${N}-node testnet at ${BASE_DIR}…"

  # Use normal binary for init-files
  local cmd=("$BINARY_NORMAL" testnet init-files \
    --validator-count "${N}" \
    --keyring-backend test \
    --output-dir "${BASE_DIR}")

  if "$BINARY_NORMAL" testnet init-files --help 2>/dev/null | grep -q -- "--chain-id"; then
    cmd+=(--chain-id "${CHAIN_ID}")
  fi
  if [ "${SINGLE_HOST}" = "true" ] && "$BINARY_NORMAL" testnet init-files --help 2>/dev/null | grep -q -- "--single-host"; then
    cmd+=(--single-host=true)
  fi
  if [ "${SINGLE_HOST}" = "true" ] && "$BINARY_NORMAL" testnet init-files --help 2>/dev/null | grep -q -- "--starting-ip-address"; then
    cmd+=(--starting-ip-address "${STARTING_IP_ADDRESS}")
  fi

  printf '[evmd-localnet-mixed] Exec: '
  for a in "${cmd[@]}"; do printf '%s ' "$a"; done; printf '\n'
  "${cmd[@]}"

  log "Init complete (chain-id: ${CHAIN_ID}). Genesis and configs under ${BASE_DIR}/${NODE_PREFIX}{0..$((N-1))}/evmd"

  # Fallback: patch genesis chain_id via jq if init-files doesn't support --chain-id
  if ! "$BINARY_NORMAL" testnet init-files --help 2>/dev/null | grep -q -- "--chain-id"; then
    if command -v jq >/dev/null 2>&1; then
      for ((i=0; i<N; i++)); do
        gi="${BASE_DIR}/${NODE_PREFIX}${i}/evmd/config/genesis.json"
        if [ -f "$gi" ]; then
          tmp="$gi.tmp" && jq --arg cid "$CHAIN_ID" '.chain_id=$cid' "$gi" > "$tmp" && mv "$tmp" "$gi"
        fi
      done
      log "Patched genesis chain_id to '${CHAIN_ID}' via jq (fallback path)."
    else
      log "jq not found; cannot patch genesis chain_id. Using defaults from init-files."
    fi
  fi
}

adjust_ports_single_host() {
  if [ "${SINGLE_HOST}" != "true" ]; then
    log "SINGLE_HOST is not enabled; skipping port adjustments."
    return 0
  fi

  toml_set_key_in_section() {
    local file="$1" section="$2" key="$3" value="$4"
    awk -v section="$section" -v key="$key" -v value="$value" '
      BEGIN { insec=0; done=0 }
      /^[[:space:]]*\[/ {
        if (insec && !done) { print key " = \"" value "\""; done=1 }
        insec=0
        if ($0 ~ "^\\[" section "\\]") { insec=1 }
        print; next
      }
      {
        if (insec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=") {
          print key " = \"" value "\""; done=1; next
        }
        print
      }
      END {
        if (insec && !done) { print key " = \"" value "\"" }
      }
    ' "$file" >"$file.tmp" && mv "$file.tmp" "$file"
  }

  for ((i=0; i<N; i++)); do
    local home_dir="${BASE_DIR}/${NODE_PREFIX}${i}/evmd"
    local cfg_tm="${home_dir}/config/config.toml"
    local cfg_app="${home_dir}/config/app.toml"

    [ -f "$cfg_tm" ] || { err "Missing $cfg_tm"; continue; }
    [ -f "$cfg_app" ] || { err "Missing $cfg_app"; continue; }

    local rpc_port=$((26657 + i))
    local p2p_port=$((16656 + i))
    local pprof_port=$((6060 + i))
    local prom_port=$((26660 + i))
    local api_port=$((1317 + i))
    local grpc_port=$((9090 + i))
    local grpcweb_port=$((9091 + i))
    local http_port=$((8545 + i*10))
    local ws_port=$((8546 + i*10))

    toml_set_key_in_section "$cfg_tm" "rpc" "laddr" "tcp://127.0.0.1:${rpc_port}"
    toml_set_key_in_section "$cfg_tm" "rpc" "pprof_laddr" "localhost:${pprof_port}"
    toml_set_key_in_section "$cfg_tm" "p2p" "laddr" "tcp://127.0.0.1:${p2p_port}"
    toml_set_key_in_section "$cfg_tm" "instrumentation" "prometheus_listen_addr" ":${prom_port}"

    toml_set_key_in_section "$cfg_app" "api" "address" "tcp://127.0.0.1:${api_port}"
    toml_set_key_in_section "$cfg_app" "grpc" "address" "127.0.0.1:${grpc_port}"
    toml_set_key_in_section "$cfg_app" "grpc-web" "address" "127.0.0.1:${grpcweb_port}"
    toml_set_key_in_section "$cfg_app" "json-rpc" "address" "127.0.0.1:${http_port}"
    toml_set_key_in_section "$cfg_app" "json-rpc" "ws-address" "127.0.0.1:${ws_port}"

    log "Configured ${NODE_PREFIX}${i} ports: rpc:${rpc_port} p2p:${p2p_port} api:${api_port} http:${http_port} ws:${ws_port} grpc:${grpc_port}/${grpcweb_port}"
  done
}

tune_timeouts() {
  for ((i=0; i<N; i++)); do
    local CONFIG_TOML="${BASE_DIR}/${NODE_PREFIX}${i}/evmd/config/config.toml"
    if [ ! -f "$CONFIG_TOML" ]; then
      err "Missing $CONFIG_TOML"
      continue
    fi
    sed -i.bak 's/log_level = "info"/log_level = "debug"/g' "$CONFIG_TOML"
    sed -i.bak 's/log_format = "plain"/log_format = "json"/g' "$CONFIG_TOML"
    sed -i.bak 's/timeout_propose = "3s"/timeout_propose = "2s"/g' "$CONFIG_TOML"
    sed -i.bak 's/timeout_propose_delta = "500ms"/timeout_propose_delta = "200ms"/g' "$CONFIG_TOML"
    sed -i.bak 's/timeout_prevote = "1s"/timeout_prevote = "500ms"/g' "$CONFIG_TOML"
    sed -i.bak 's/timeout_prevote_delta = "500ms"/timeout_prevote_delta = "200ms"/g' "$CONFIG_TOML"
    sed -i.bak 's/timeout_precommit = "1s"/timeout_precommit = "500ms"/g' "$CONFIG_TOML"
    sed -i.bak 's/timeout_precommit_delta = "500ms"/timeout_precommit_delta = "200ms"/g' "$CONFIG_TOML"
    sed -i.bak 's/timeout_commit = "5s"/timeout_commit = "1s"/g' "$CONFIG_TOML"
    sed -i.bak 's/timeout_broadcast_tx_commit = "10s"/timeout_broadcast_tx_commit = "5s"/g' "$CONFIG_TOML"
  done
  log "Applied consensus timeout adjustments to all nodes."
}

adjust_memlogger() {
  for ((i=0; i<N; i++)); do
    local APP_TOML="${BASE_DIR}/${NODE_PREFIX}${i}/evmd/config/app.toml"
    if [ ! -f "$APP_TOML" ]; then
      err "Missing $APP_TOML"
      continue
    fi

    toml_set_key_in_section() {
      local file="$1" section="$2" key="$3" value="$4"
      awk -v section="$section" -v key="$key" -v value="$value" '
        BEGIN { insec=0; done=0 }
        /^[[:space:]]*\[/ {
          if (insec && !done) { print key " = \"" value "\""; done=1 }
          insec=0
          if ($0 ~ "^\\[" section "\\]") { insec=1 }
          print; next
        }
        {
          if (insec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=") {
            print key " = \"" value "\""; done=1; next
          }
          print
        }
        END {
          if (insec && !done) { print key " = \"" value "\"" }
        }
      ' "$file" >"$file.tmp" && mv "$file.tmp" "$file"
    }

    toml_set_key_in_section_raw() {
      local file="$1" section="$2" key="$3" rawvalue="$4"
      awk -v section="$section" -v key="$key" -v rawvalue="$rawvalue" '
        BEGIN { insec=0; done=0 }
        /^[[:space:]]*\[/ {
          if (insec && !done) { print key " = " rawvalue; done=1 }
          insec=0
          if ($0 ~ "^\\[" section "\\]") { insec=1 }
          print; next
        }
        {
          if (insec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=") {
            print key " = " rawvalue; done=1; next
          }
          print
        }
        END {
          if (insec && !done) { print key " = " rawvalue }
        }
      ' "$file" >"$file.tmp" && mv "$file.tmp" "$file"
    }

    toml_set_key_in_section "$APP_TOML" "memlogger" "enabled" "true"
    toml_set_key_in_section "$APP_TOML" "memlogger" "interval" "2s"
    toml_set_key_in_section_raw "$APP_TOML" "memlogger" "memory-bytes" "104857600"
  done
  log "Enabled memlogger for all nodes."
}

apply_surge_and_replicate() {
  local g0="${BASE_DIR}/${NODE_PREFIX}0/evmd/config/genesis.json"
  if [ ! -f "$g0" ]; then
    err "node0 genesis not found at $g0"
    exit 1
  fi

  if [ -n "$SURGE_CMD" ]; then
    local surge_bin
    surge_bin=$(echo "$SURGE_CMD" | awk '{print $1}')
    if ! command -v "$surge_bin" >/dev/null 2>&1; then
      err "'$surge_bin' not found on PATH. Set SURGE_CMD='' to skip or install surge."
      exit 1
    fi
    printf '[evmd-localnet-mixed] Exec: %s %s %s\n' "$SURGE_CMD" "${SURGE_ARGS}" "$g0"
    eval "$SURGE_CMD ${SURGE_ARGS} $g0"
  else
    log "SURGE_CMD empty; skipping surge faucet step."
  fi

  for ((i=1; i<N; i++)); do
    local gi="${BASE_DIR}/${NODE_PREFIX}${i}/evmd/config/genesis.json"
    if [ -f "$gi" ]; then
      cp "$g0" "$gi"
    fi
  done

  for ((i=0; i<N; i++)); do
    local home_dir="${BASE_DIR}/${NODE_PREFIX}${i}/evmd"
    if [ -d "$home_dir" ]; then
      "$BINARY_NORMAL" genesis validate-genesis --home "$home_dir" >/dev/null 2>&1 || true
    fi
  done
}

build_peers_if_possible() {
  if ! "$BINARY_NORMAL" comet --help >/dev/null 2>&1; then
    log "'evmd comet' subcommand not found. Skipping persistent_peers injection."
    return 0
  fi

  local peers=""
  for ((i=0; i<N; i++)); do
    local home_dir="${BASE_DIR}/${NODE_PREFIX}${i}/evmd"
    local id
    if ! id=$("$BINARY_NORMAL" comet show-node-id --home "$home_dir" 2>/dev/null); then
      err "Failed to read node ID for ${NODE_PREFIX}${i}; skipping persistent_peers."
      return 0
    fi
    local p2p_port=$((16656 + i))
    local entry="${id}@127.0.0.1:${p2p_port}"
    if [ -z "$peers" ]; then peers="$entry"; else peers+=",$entry"; fi
  done

  log "persistent_peers=${peers}"
  for ((i=0; i<N; i++)); do
    local cfg="${BASE_DIR}/${NODE_PREFIX}${i}/evmd/config/config.toml"
    if [ -f "$cfg" ]; then
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

  for ((i=0; i<N; i++)); do
    local home_dir="${BASE_DIR}/${NODE_PREFIX}${i}/evmd"
    local log_file="${home_dir}/evmd.log"

    # Determine which binary to use
    local BINARY
    if [ $i -eq 0 ]; then
      BINARY="$BINARY_BROKEN"
      log "Node ${i} will use BROKEN binary (consensus_break)"
    else
      BINARY="$BINARY_NORMAL"
      log "Node ${i} will use NORMAL binary"
    fi

    local rpc_port=$((26657 + i))
    local p2p_port=$((16656 + i))
    local api_port=$((1317 + i))
    local http_port=$((8545 + i*10))
    local ws_port=$((8546 + i*10))

    log "Starting ${NODE_PREFIX}${i} (rpc:${rpc_port}, p2p:${p2p_port}, api:${api_port}, http:${http_port}, ws:${ws_port})"

    "$BINARY" config set client chain-id "${CHAIN_ID}" --home "$home_dir" >/dev/null 2>&1 || true

    cmd=("$BINARY" start \
      --home "$home_dir" \
      --minimum-gas-prices "${MIN_GAS_PRICES}" \
      --evm.min-tip 0 \
      --json-rpc.api "eth,txpool,personal,net,debug,web3" \
      --chain-id "${CHAIN_ID}")

    printf '[evmd-localnet-mixed] Exec: '
    for arg in "${cmd[@]}"; do printf '%s ' "$arg"; done; printf '\n'

    ("${cmd[@]}" >"$log_file" 2>&1 & echo $! >> "$PID_FILE")
    sleep 0.5
  done

  log "All nodes started. PIDs recorded in ${PID_FILE}"
  log "Node0 (broken) running on: rpc=26657, http=8545"
  log "Node1 (normal) running on: rpc=26658, http=8555"
  log "Node2 (normal) running on: rpc=26659, http=8565"
  log "Node3 (normal) running on: rpc=26660, http=8575"
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
  log "Clean complete."
}

cmd=${1:-start}
case "$cmd" in
  setup)
    setup_binaries
    ;;
  start)
    verify_binaries
    init_fresh
    apply_surge_and_replicate
    adjust_ports_single_host
    tune_timeouts
    adjust_memlogger
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
    echo "Usage: $0 {setup|start|stop|clean}" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  setup  - Build both normal and broken evmd binaries" >&2
    echo "  start  - Initialize and start 4 nodes (1 broken, 3 normal)" >&2
    echo "  stop   - Stop all running nodes" >&2
    echo "  clean  - Remove all test data and binaries" >&2
    exit 1
    ;;
esac
