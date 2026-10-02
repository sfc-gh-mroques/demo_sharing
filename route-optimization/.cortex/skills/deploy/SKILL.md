---
name: deploy
description: "Deploy the route optimization solution from scratch on any Snowflake account. Creates infrastructure, loads data, provisions ORS routing, runs the optimizer, and deploys the web app. Triggers: deploy, install, setup, deploy route optimization, deploy app."
metadata:
  author: Fleet Intelligence
  version: 1.0.0
  category: deployment
---

# Deploy Route Optimization Solution

Deploys the complete route optimization solution on a Snowflake account.

## Prerequisites

- ACCOUNTADMIN access (only for initial role/integration creation in Step 1)
- Docker running locally (for app image build)
- ORS app installed (`OPENROUTESERVICE_APP` database exists with services RUNNING)
  - If not: clone `https://github.com/Snowflake-Labs/sfguide-Create-a-Route-Optimisation-and-Vehicle-Route-Plan-Simulator` and run `$build-routing-solution`
- A provisioned ORS region covering the delivery area
  - If not: see Step 3 below

## Required Privileges

The deployment uses **two roles** following least-privilege:

| Role | Used for | Privileges needed |
|------|----------|-------------------|
| ACCOUNTADMIN | Step 1 only (one-time setup) | CREATE DATABASE, CREATE WAREHOUSE, CREATE ROLE, CREATE COMPUTE POOL, CREATE INTEGRATION |
| ROUTE_OPTIMIZATION_ROLE | Steps 2-7 (all operations) | USAGE on DB/schema/warehouse, CREATE TABLE/VIEW/PROCEDURE, USAGE on ORS functions |

After Step 1 completes, **all subsequent steps use ROUTE_OPTIMIZATION_ROLE** (no ACCOUNTADMIN needed).

## Workflow

### Step 1: Initial Infrastructure (ACCOUNTADMIN — one time only)

**Goal:** Create the database, schema, warehouse, role, compute pool, network rule, EAI, and image repo. Grant ORS access.

**Actions:**

1. Run the infrastructure setup:
```sql
USE ROLE ACCOUNTADMIN;

-- Database and schema
CREATE DATABASE IF NOT EXISTS FLEET_INTELLIGENCE;
CREATE SCHEMA IF NOT EXISTS FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION;

-- Warehouse
CREATE WAREHOUSE IF NOT EXISTS ROUTING_WH
  WAREHOUSE_SIZE = 'MEDIUM' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE;

-- Role
CREATE ROLE IF NOT EXISTS ROUTE_OPTIMIZATION_ROLE;
GRANT ROLE ROUTE_OPTIMIZATION_ROLE TO ROLE SYSADMIN;

-- Grants to role
GRANT USAGE ON DATABASE FLEET_INTELLIGENCE TO ROLE ROUTE_OPTIMIZATION_ROLE;
GRANT ALL ON SCHEMA FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION TO ROLE ROUTE_OPTIMIZATION_ROLE;
GRANT USAGE ON WAREHOUSE ROUTING_WH TO ROLE ROUTE_OPTIMIZATION_ROLE;

-- ORS access
GRANT USAGE ON DATABASE OPENROUTESERVICE_APP TO ROLE ROUTE_OPTIMIZATION_ROLE;
GRANT USAGE ON SCHEMA OPENROUTESERVICE_APP.CORE TO ROLE ROUTE_OPTIMIZATION_ROLE;
GRANT USAGE ON FUNCTION OPENROUTESERVICE_APP.CORE._OPTIMIZATION_RAW(VARIANT, VARCHAR) TO ROLE ROUTE_OPTIMIZATION_ROLE;
GRANT USAGE ON FUNCTION OPENROUTESERVICE_APP.CORE._DIRECTIONS_RAW(VARCHAR, VARIANT, VARCHAR) TO ROLE ROUTE_OPTIMIZATION_ROLE;
GRANT USAGE ON FUNCTION OPENROUTESERVICE_APP.CORE.ORS_STATUS(VARCHAR) TO ROLE ROUTE_OPTIMIZATION_ROLE;
GRANT USAGE ON FUNCTION OPENROUTESERVICE_APP.CORE.ORS_STATUS() TO ROLE ROUTE_OPTIMIZATION_ROLE;

-- Compute pool for web app
CREATE COMPUTE POOL IF NOT EXISTS ROUTE_OPTIMIZATION_POOL
  MIN_NODES = 1 MAX_NODES = 1 INSTANCE_FAMILY = CPU_X64_XS
  AUTO_SUSPEND_SECS = 3600 AUTO_RESUME = TRUE;
GRANT USAGE, MONITOR ON COMPUTE POOL ROUTE_OPTIMIZATION_POOL TO ROLE ROUTE_OPTIMIZATION_ROLE;

-- Network rule + EAI for map tiles
CREATE OR REPLACE NETWORK RULE FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION.MAP_TILES_RULE
  MODE = EGRESS TYPE = HOST_PORT
  VALUE_LIST = ('a.basemaps.cartocdn.com:443','b.basemaps.cartocdn.com:443','c.basemaps.cartocdn.com:443','d.basemaps.cartocdn.com:443');
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION MAP_TILES_EAI
  ALLOWED_NETWORK_RULES = (FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION.MAP_TILES_RULE) ENABLED = TRUE;
GRANT USAGE ON INTEGRATION MAP_TILES_EAI TO ROLE ROUTE_OPTIMIZATION_ROLE;

-- Image repo
CREATE IMAGE REPOSITORY IF NOT EXISTS FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION.IMAGES;
GRANT READ, WRITE ON IMAGE REPOSITORY FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION.IMAGES TO ROLE ROUTE_OPTIMIZATION_ROLE;

-- BIND SERVICE ENDPOINT for public app
GRANT BIND SERVICE ENDPOINT ON ACCOUNT TO ROLE ROUTE_OPTIMIZATION_ROLE;

-- Grant role to current user
GRANT ROLE ROUTE_OPTIMIZATION_ROLE TO USER IDENTIFIER(CURRENT_USER());
```

2. **Verify:** `SHOW GRANTS TO ROLE ROUTE_OPTIMIZATION_ROLE;` — should show all grants above.

**Output:** Infrastructure created. From now on, use ROUTE_OPTIMIZATION_ROLE for everything.

### Step 2: Create Tables and Load Data (ROUTE_OPTIMIZATION_ROLE)

**Goal:** Create input/output tables and load sample data.

**Actions:**

1. Switch to the app role:
```sql
USE ROLE ROUTE_OPTIMIZATION_ROLE;
USE DATABASE FLEET_INTELLIGENCE;
USE SCHEMA ROUTE_OPTIMIZATION;
USE WAREHOUSE ROUTING_WH;
```

2. Run `setup/setup.sql` to create tables (DEPOT, CAMION, CAPACITE_CAMION, COMMANDES, OPTIMIZATION_RESULTS).

3. Load data — either:
   - Insert sample data from `data/sample/*.csv` using INSERT VALUES
   - Or COPY INTO from a stage

4. **Verify:** `SELECT COUNT(*) FROM DEPOT; SELECT COUNT(*) FROM COMMANDES;`

**Output:** Tables populated with delivery data.

### Step 3: Provision ORS Region (ACCOUNTADMIN — if not already done)

**Goal:** Download map data and build routing graph for the delivery area.

**Actions:**

```sql
-- Provision Ile-de-France (~15 min build time)
CALL OPENROUTESERVICE_APP.CORE.PROVISION_REGION_WRAPPER(
    'job_idf', 'idf', 'Ile-de-France',
    'https://download.geofabrik.de/europe/france/ile-de-france-latest.osm.pbf',
    48.1, 49.2, 1.4, 3.6, 'driving-hgv'
);
```

Wait for completion:
```sql
SELECT OPENROUTESERVICE_APP.CORE.ORS_STATUS('idf'):service_ready;
-- Must return: true
```

**IMPORTANT:** Ensure all delivery points in COMMANDES are within the map bounds. Points outside will cause VROOM errors (code 3).

**Output:** ORS region ready for routing.

### Step 4: Create Views (ROUTE_OPTIMIZATION_ROLE)

**Goal:** Create analytical views that compute exact distances from VROOM geometry.

**Actions:**

1. Run `setup/setup.sql`

2. **Verify:** `SELECT * FROM ROUTE_KPI;` — should return 1 row (may be empty if optimizer hasn't run yet).

**Output:** Views ROUTE_METRICS and ROUTE_KPI created.

### Step 5: Deploy Optimizer Stored Procedure (ROUTE_OPTIMIZATION_ROLE)

**Goal:** Deploy the GA optimizer as a callable SQL procedure.

**Actions:**

1. The file `setup/optimizer_sproc.sql` contains a CREATE PROCEDURE with a Python body using `$$` delimiters. Due to `$$` appearing inside the Python code, it must be deployed via the Python Snowflake connector:

```python
import snowflake.connector
conn = snowflake.connector.connect(connection_name='<CONNECTION>')
cur = conn.cursor()
cur.execute('USE ROLE ROUTE_OPTIMIZATION_ROLE')
cur.execute('USE DATABASE FLEET_INTELLIGENCE')
cur.execute('USE SCHEMA ROUTE_OPTIMIZATION')
cur.execute('USE WAREHOUSE ROUTING_WH')
with open('setup/optimizer_sproc.sql') as f:
    content = f.read()
start = content.find('CREATE OR REPLACE PROCEDURE')
end = content.rfind('$$;') + 3
cur.execute(content[start:end])
print('Procedure created')
conn.close()
```

2. **Verify:** `SHOW PROCEDURES LIKE 'OPTIMIZE_ROUTES' IN SCHEMA FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION;`

**Output:** Stored procedure OPTIMIZE_ROUTES available.

### Step 6: Run Optimization (ROUTE_OPTIMIZATION_ROLE)

**Goal:** Run the optimizer to compute delivery routes.

**Actions:**

```sql
USE ROLE ROUTE_OPTIMIZATION_ROLE;
CALL OPTIMIZE_ROUTES('idf', 5, TRUE);
-- Parameters: region name (or NULL for default), max vehicles, multi-tour enabled
-- Takes ~1 min with 8 pop x 3 gen on 13 IDF commandes
```

**Verify:**
```sql
SELECT * FROM ROUTE_KPI;
-- Should show: nb_vehicules, total_livraisons, distance_totale_km, etc.
SELECT VEHICLE_ID, VEHICLE_DESCRIPTION, DISTANCE_KM, NB_LIVRAISONS FROM ROUTE_METRICS;
```

**Output:** Optimization results stored, views populated.

### Step 7: Deploy Web App (ROUTE_OPTIMIZATION_ROLE)

**Goal:** Build and deploy the Next.js dashboard to SPCS.

**Actions:**

1. Get account locator:
```sql
SELECT CURRENT_ACCOUNT_LOCATOR();
```

2. Run the deploy script:
```bash
cd deploy/
./deploy.sh --account-locator <LOCATOR> --connection <CONNECTION>
```

This builds the Docker image, pushes to the Snowflake registry, and creates the SPCS service.

3. **Verify:** The script prints the app URL. Open it and log in with Snowflake credentials.

**Output:** Dashboard accessible showing routes, map, KPIs.

## Stopping Points

- After Step 1: Verify role grants before proceeding
- After Step 3: Wait for ORS_STATUS to return true before running optimizer
- After Step 6: Verify ROUTE_KPI returns data before deploying app

## Known Issues and Workarounds

### Docker image pull fails in SPCS ("Failed to pull image")

Docker Desktop on Mac produces OCI manifest lists (with provenance/SBOM attestations) that SPCS cannot pull. Always build with:

```bash
docker build --platform linux/amd64 --provenance=false --sbom=false -t <image> .
```

The `deploy.sh` script already includes these flags.

### SPCS service spec image path format

Service specs must use the **internal path** (no registry hostname):
```
/fleet_intelligence/route_optimization/images/route-optimization-app:latest
```
NOT the full registry URL (`<org>-<account>.registry.snowflakecomputing.com/...`).

### ORS stored procedures need SYSADMIN grants

ORS procedures (`WRITE_ORS_CONFIG`, `CREATE_REGION_ORS_SERVICE`) execute as OWNER (SYSADMIN). They need:
```sql
GRANT USAGE, MONITOR, OPERATE ON COMPUTE POOL OPENROUTESERVICE_APP_COMPUTE_POOL TO ROLE SYSADMIN;
GRANT ALL ON ALL STAGES IN SCHEMA OPENROUTESERVICE_APP.CORE TO ROLE SYSADMIN;
GRANT READ ON IMAGE REPOSITORY OPENROUTESERVICE_APP.CORE.IMAGE_REPOSITORY TO ROLE SYSADMIN;
GRANT USAGE ON INTEGRATION ORS_OSM_EAI TO ROLE SYSADMIN;
```

### WRITE_ORS_CONFIG argument order

The signature is `WRITE_ORS_CONFIG(region, pbf_filename, profiles)`:
```sql
CALL WRITE_ORS_CONFIG('idf', 'ile-de-france-latest.osm.pbf', 'driving-hgv');
-- NOT: WRITE_ORS_CONFIG('idf', 'driving-hgv', 'ile-de-france-latest.osm.pbf')
```

### IDF graph build time

After creating the ORS region service, the routing graph takes 5-10 minutes to build. Poll with:
```sql
SELECT OPENROUTESERVICE_APP.CORE.ORS_STATUS('idf'):service_ready::VARCHAR;
-- Wait until 'true'
```

## Verification

Final end-to-end check:
```sql
USE ROLE ROUTE_OPTIMIZATION_ROLE;
SELECT * FROM FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION.ROUTE_KPI;
-- Must show: nb_vehicules > 0, distance_totale_km > 0, nb_non_assignees >= 0
```

## Cleanup

```sql
USE ROLE ACCOUNTADMIN;
DROP SERVICE IF EXISTS FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION.ROUTE_OPTIMIZATION_APP;
DROP COMPUTE POOL IF EXISTS ROUTE_OPTIMIZATION_POOL;
DROP SCHEMA IF EXISTS FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION CASCADE;
DROP ROLE IF EXISTS ROUTE_OPTIMIZATION_ROLE;
DROP WAREHOUSE IF EXISTS ROUTING_WH;
DROP INTEGRATION IF EXISTS MAP_TILES_EAI;
```
