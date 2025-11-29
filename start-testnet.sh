#!/bin/bash

# Interactive script to start a new testnet with apphash.io integration
set -e

# Parse arguments
NODE_COUNT=4
SERVICE_BASE="http://host.docker.internal:8080"
AUTH_KEY=""
CUSTOM_CHAIN_ID=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --nodes|-n)
      NODE_COUNT="$2"
      shift 2
      ;;
    --url|-u)
      SERVICE_BASE="$2"
      shift 2
      ;;
    --chain-id|-c)
      CUSTOM_CHAIN_ID="$2"
      shift 2
      ;;
    --auth-key|-k)
      AUTH_KEY="$2"
      shift 2
      ;;
    *)
      NODE_COUNT="$1"
      shift
      ;;
  esac
done

echo "============================================="
echo "  EVM Testnet Launcher with apphash.io"
echo "============================================="
echo ""

# Step 1: Configure Chain ID
if [ -n "$CUSTOM_CHAIN_ID" ]; then
  CHAIN_ID="$CUSTOM_CHAIN_ID"
else
  DEFAULT_CHAIN_ID="testnet-$(date +%s)"
  if [ -n "$AUTH_KEY" ]; then
    CHAIN_ID="$DEFAULT_CHAIN_ID"
  else
    echo "Step 1: Configure Chain ID"
    echo ""
    read -p "Enter Chain ID (default: $DEFAULT_CHAIN_ID): " USER_CHAIN_ID
    CHAIN_ID="${USER_CHAIN_ID:-$DEFAULT_CHAIN_ID}"
    echo ""
  fi
fi

echo "Using Chain ID: $CHAIN_ID"
echo ""

COMPOSE_FILE="docker-compose.${CHAIN_ID}.yml"

# Step 2: Get Auth Key (if not provided)
if [ -z "$AUTH_KEY" ]; then
  echo "============================================="
  echo "Step 2: Create project on apphash.io"
  echo "============================================="
  echo ""
  echo "  1. Go to: https://apphash.io"
  echo "  2. Click 'New Project'"
  echo "  3. Enter Chain ID: $CHAIN_ID"
  echo "  4. Copy the generated Auth Key"
  echo ""
  read -p "Paste the Auth Key here: " AUTH_KEY

  if [ -z "$AUTH_KEY" ]; then
    echo "Error: Auth Key cannot be empty"
    exit 1
  fi
  echo ""
fi

# Step 3: Clean up old data
echo "Step 3: Cleaning up old data..."
docker compose -f "$COMPOSE_FILE" down -v 2>/dev/null || true
rm -rf .testnets
mkdir -p .testnets
echo ""

# Step 4: Generate docker-compose and start testnet
echo "Step 4: Generating docker-compose and starting testnet..."
echo "  Chain ID: $CHAIN_ID"
echo "  Validators: $NODE_COUNT"
echo ""

# Generate docker-compose.yml with init + setup + nodes + shippers
cat > "$COMPOSE_FILE" <<COMPOSE_HEADER

services:
  # Setup Service (Initialize and Configure)
  setup:
    container_name: setup
    build:
      context: .
      dockerfile: contrib/images/evmd-env/Dockerfile
    user: root
    entrypoint: []
    command: |
      sh -c "
      echo 'Initializing testnet with Chain ID: $CHAIN_ID...'
      evmd testnet init-files --validator-count $NODE_COUNT --output-dir /data --chain-id $CHAIN_ID --keyring-backend test

      echo 'Configuring network binding...'
      find /data -name config.toml -exec sed -i 's/127.0.0.1/0.0.0.0/g' {} +

      echo 'Enabling MemLogger...'
      find /data -name app.toml -exec sed -i 's/enabled = false/enabled = true/g' {} +

      echo 'Configuring persistent peers...'
      PEERS=''
      for i in \$\$(seq 0 $((NODE_COUNT - 1))); do
        NODE_ID=\$\$(evmd comet show-node-id --home /data/node\$\$i/evmd)
        if [ -z \"\$\$PEERS\" ]; then
          PEERS=\"\$\$NODE_ID@evmdnode\$\$i:26656\"
        else
          PEERS=\"\$\$PEERS,\$\$NODE_ID@evmdnode\$\$i:26656\"
        fi
      done
      echo \"Peers: \$\$PEERS\"
      for i in \$\$(seq 0 $((NODE_COUNT - 1))); do
        sed -i 's#^persistent_peers = .*#persistent_peers = \"'\"\$\$PEERS\"'\"#' /data/node\$\$i/evmd/config/config.toml
      done

      echo 'Fixing permissions...'
      chown -R 1025:1025 /data
      echo 'Setup complete!'
      "
    volumes:
      - ./.testnets:/data:Z

COMPOSE_HEADER

# Generate node services
for i in $(seq 0 $((NODE_COUNT - 1))); do
  P2P_PORT=$((26656 + i * 10))
  RPC_PORT=$((26657 + i * 10))
  API_PORT=$((1317 + i))
  JSONRPC_PORT=$((8545 + i * 10))

  cat >> "$COMPOSE_FILE" <<NODE_SERVICE
  # EVM Node $i
  evmdnode$i:
    container_name: evmdnode$i
    build:
      context: .
      dockerfile: contrib/images/evmd-env/Dockerfile
    environment:
      - DEBUG=0
      - ID=$i
      - LOG=evmd.log
    depends_on:
      setup:
        condition: service_completed_successfully
    command: start --chain-id $CHAIN_ID --minimum-gas-prices 0atest --json-rpc.enable true --json-rpc.api eth,txpool,personal,net,debug,web3
    ports:
      - "$P2P_PORT-$RPC_PORT:26656-26657"
      - "$API_PORT:1317"
      - "$JSONRPC_PORT:8545"
    volumes:
      - ./.testnets:/data:Z
    networks:
      - localnet

NODE_SERVICE

  cat >> "$COMPOSE_FILE" <<SHIPPER_SERVICE
  # Shipper $i
  walship$i:
    image: ghcr.io/bft-labs/cosmos-analyzer-shipper:latest
    container_name: walship$i
    restart: always
    depends_on:
      - evmdnode$i
    volumes:
      - ./.testnets:/data:ro
    environment:
      - WALSHIP_NODE_HOME=/data/node$i/evmd
      - WALSHIP_SERVICE_URL=$SERVICE_BASE/v1/ingest
      - WALSHIP_AUTH_KEY=$AUTH_KEY
    networks:
      - localnet
SHIPPER_SERVICE
done

# Add networks section
cat >> "$COMPOSE_FILE" <<COMPOSE_FOOTER

networks:
  localnet:
    driver: bridge
COMPOSE_FOOTER

echo "Generated: $COMPOSE_FILE"
echo ""

# Start the testnet
echo "Starting testnet..."
docker compose -f "$COMPOSE_FILE" up -d --build 2>&1 | grep -v "View in Docker Desktop" | grep -v "View Config" | grep -v "Enable Watch"

echo ""
echo "============================================="
echo "  Testnet is running!"
echo "============================================="
echo ""
echo "Chain ID:  $CHAIN_ID"
echo "Nodes:     $NODE_COUNT"
echo "Auth Key:  ${AUTH_KEY:0:8}...${AUTH_KEY: -8}"
echo ""
echo "Monitor your testnet:"
echo "  https://apphash.io"
echo ""
echo "View logs:"
echo "  docker compose -f $COMPOSE_FILE logs -f"
echo ""
echo "Stop testnet:"
echo "  docker compose -f $COMPOSE_FILE down"
echo ""
echo "Clean up all data:"
echo "  docker compose -f $COMPOSE_FILE down -v && rm -rf .testnets"
echo ""
