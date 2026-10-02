#!/bin/bash
# =============================================================================
# deploy.sh — Build, push, and deploy the Route Optimization app to SPCS
#
# Usage:
#   ./deploy.sh --account-locator AB12345 \
#               --region eu-west-3 \
#               --database FLEET_INTELLIGENCE \
#               --schema ROUTE_OPTIMIZATION \
#               --connection <NOM_CONNEXION>
#
# Prerequisites:
#   - Docker running locally
#   - SnowCLI installed (snow --version)
#   - setup/setup.sql already executed on the target account
# =============================================================================

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────
ACCOUNT_LOCATOR=""
DATABASE="FLEET_INTELLIGENCE"
SCHEMA="ROUTE_OPTIMIZATION"
WAREHOUSE="ROUTING_WH"
CONNECTION="default"
COMPUTE_POOL="ROUTE_OPTIMIZATION_POOL"
SERVICE_NAME="ROUTE_OPTIMIZATION_APP"
EAI_NAME="MAP_TILES_EAI"
IMAGE_NAME="route-optimization-app"

# ─── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --account-locator) ACCOUNT_LOCATOR="$2"; shift 2 ;;
    --database) DATABASE="$2"; shift 2 ;;
    --schema) SCHEMA="$2"; shift 2 ;;
    --warehouse) WAREHOUSE="$2"; shift 2 ;;
    --connection) CONNECTION="$2"; shift 2 ;;
    --compute-pool) COMPUTE_POOL="$2"; shift 2 ;;
    --service-name) SERVICE_NAME="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --account-locator <LOCATOR> [options]"
      echo ""
      echo "Required:"
      echo "  --account-locator   Snowflake account locator (e.g. AB12345)"
      echo ""
      echo "Optional:"
      echo "  --database          Database name (default: FLEET_INTELLIGENCE)"
      echo "  --schema            Schema name (default: ROUTE_OPTIMIZATION)"
      echo "  --warehouse         Warehouse name (default: ROUTING_WH)"
      echo "  --connection        SnowCLI connection name (default: default)"
      echo "  --compute-pool      Compute pool name (default: ROUTE_OPTIMIZATION_POOL)"
      echo "  --service-name      SPCS service name (default: ROUTE_OPTIMIZATION_APP)"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ -z "$ACCOUNT_LOCATOR" ]; then
  echo "ERROR: --account-locator is required"
  echo "  Find yours with: snow sql -q \"SELECT CURRENT_ACCOUNT_LOCATOR()\" --connection <name>"
  exit 1
fi

# ─── Derived values ───────────────────────────────────────────────────────────
# NOTE: Do NOT set SNOWFLAKE_HOST in the service spec.
# The Node.js SDK auto-derives the correct internal hostname (which includes
# internal routing info like 'prod3') from the account locator alone.
# Manually setting SNOWFLAKE_HOST will likely FAIL because the internal SPCS
# hostname format is unpredictable (e.g. <locator>.prod3.<region>.aws...).

# Get registry URL from SnowCLI
echo "=== Getting image repository URL..."
REGISTRY_URL=$(snow sql -q "SELECT repository_url FROM INFORMATION_SCHEMA.IMAGE_REPOSITORIES WHERE REPOSITORY_NAME = 'IMAGES' AND CATALOG_NAME = '${DATABASE}' AND SCHEMA_NAME = '${SCHEMA}'" --connection "$CONNECTION" --format json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['REPOSITORY_URL'])" 2>/dev/null || true)

if [ -z "$REGISTRY_URL" ]; then
  # Fallback: construct from known pattern
  REGISTRY_HOST=$(snow spcs image-registry url --connection "$CONNECTION" 2>/dev/null | tr -d '\n' || true)
  if [ -z "$REGISTRY_HOST" ]; then
    echo "ERROR: Could not determine image registry URL. Ensure setup/setup.sql was run."
    exit 1
  fi
  DB_LOWER=$(echo "$DATABASE" | tr '[:upper:]' '[:lower:]')
  SCHEMA_LOWER=$(echo "$SCHEMA" | tr '[:upper:]' '[:lower:]')
  REGISTRY_URL="${REGISTRY_HOST}/${DB_LOWER}/${SCHEMA_LOWER}/images"
fi

IMAGE_URL="${REGISTRY_URL}/${IMAGE_NAME}"
echo "  Registry: ${REGISTRY_URL}"
echo "  Image: ${IMAGE_URL}:latest"
echo "  Account: ${ACCOUNT_LOCATOR} (SNOWFLAKE_HOST will be auto-derived by SDK)"
echo ""

# ─── Step 1: Docker build ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${SCRIPT_DIR}/../app"

echo "=== Building Docker image..."
# CRITICAL: --provenance=false --sbom=false required for SPCS compatibility.
# Without these flags, Docker Desktop produces OCI manifest lists that SPCS
# cannot pull, resulting in "Failed to pull image" errors.
docker build --platform linux/amd64 --provenance=false --sbom=false \
  -t "${IMAGE_NAME}:latest" "$APP_DIR"
echo ""

# ─── Step 2: Docker login ─────────────────────────────────────────────────────
echo "=== Logging into Snowflake image registry..."
snow spcs image-registry login --connection "$CONNECTION"
echo ""

# ─── Step 3: Tag and push ─────────────────────────────────────────────────────
echo "=== Tagging and pushing image..."
docker tag "${IMAGE_NAME}:latest" "${IMAGE_URL}:latest"
docker push "${IMAGE_URL}:latest"
echo ""

# ─── Step 4: Generate service spec ────────────────────────────────────────────
echo "=== Generating service specification..."
SPEC_FILE="${SCRIPT_DIR}/service_spec.yaml"

# SPCS service specs use INTERNAL image paths (no registry hostname).
# Format: /<database>/<schema>/<repo>/<image>:<tag>
DB_LOWER=$(echo "$DATABASE" | tr '[:upper:]' '[:lower:]')
SCHEMA_LOWER=$(echo "$SCHEMA" | tr '[:upper:]' '[:lower:]')
INTERNAL_IMAGE_PATH="/${DB_LOWER}/${SCHEMA_LOWER}/images/${IMAGE_NAME}:latest"

sed -e "s|__IMAGE_PATH__|${INTERNAL_IMAGE_PATH}|g" \
    -e "s|__ACCOUNT_LOCATOR__|${ACCOUNT_LOCATOR}|g" \
    -e "s|__DATABASE__|${DATABASE}|g" \
    -e "s|__SCHEMA__|${SCHEMA}|g" \
    -e "s|__WAREHOUSE__|${WAREHOUSE}|g" \
    "${SCRIPT_DIR}/service_spec.yaml.tpl" > "$SPEC_FILE"

echo "  Generated: ${SPEC_FILE}"
echo ""

# ─── Step 5: Drop + Create service ───────────────────────────────────────────
echo "=== Deploying service (drop + create to pull fresh image)..."
FQ_SERVICE="${DATABASE}.${SCHEMA}.${SERVICE_NAME}"

# Drop existing service (ignore error if doesn't exist)
snow sql -q "DROP SERVICE IF EXISTS ${FQ_SERVICE}" --connection "$CONNECTION" 2>/dev/null || true

# Create service
SPEC_CONTENT=$(cat "$SPEC_FILE")
snow sql -q "
CREATE SERVICE ${FQ_SERVICE}
  IN COMPUTE POOL ${COMPUTE_POOL}
  FROM SPECIFICATION \$\$
${SPEC_CONTENT}
\$\$
  EXTERNAL_ACCESS_INTEGRATIONS = (${EAI_NAME})
  QUERY_WAREHOUSE = ${WAREHOUSE}
" --connection "$CONNECTION"

echo ""

# ─── Step 6: Wait and show endpoint ──────────────────────────────────────────
echo "=== Waiting for service to start..."
for i in $(seq 1 30); do
  STATUS=$(snow sql -q "SELECT status FROM TABLE(SYSTEM\$GET_SERVICE_STATUS('${FQ_SERVICE}'))" --connection "$CONNECTION" --format json 2>/dev/null | python3 -c "import sys,json; data=json.load(sys.stdin); print(json.loads(data[0]['STATUS'])[0]['status'])" 2>/dev/null || echo "UNKNOWN")
  if [ "$STATUS" = "READY" ]; then
    break
  fi
  echo "  Status: $STATUS (attempt $i/30)"
  sleep 10
done

echo ""
echo "=== Fetching endpoint URL..."
snow sql -q "SHOW ENDPOINTS IN SERVICE ${FQ_SERVICE}" --connection "$CONNECTION"

echo ""
echo "=== Deployment complete!"
echo "  Service: ${FQ_SERVICE}"
echo "  Status: ${STATUS}"
echo ""
echo "  The app should be accessible at the 'ingress_url' shown above."
echo "  If status is not READY yet, check logs with:"
echo "    snow sql -q \"SELECT SYSTEM\$GET_SERVICE_LOGS('${FQ_SERVICE}', '0', 'app', 50)\""
