-- =============================================================================
-- setup.sql
-- Complete infrastructure setup for Route Optimization solution.
-- Creates all Snowflake objects needed before deploying the app.
-- Run with ACCOUNTADMIN role.
--
-- After this, deploy the stored procedure (08_optimizer_sproc.sql via Python)
-- and the Docker app (deploy/deploy.sh).
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. DATABASE, SCHEMA, WAREHOUSE
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE DATABASE IF NOT EXISTS FLEET_INTELLIGENCE;
CREATE SCHEMA IF NOT EXISTS FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION;

CREATE WAREHOUSE IF NOT EXISTS ROUTING_WH
  WAREHOUSE_SIZE = 'MEDIUM'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. ROLE AND GRANTS
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE ROLE IF NOT EXISTS ROUTE_OPTIMIZATION_ROLE;
GRANT ROLE ROUTE_OPTIMIZATION_ROLE TO ROLE SYSADMIN;

GRANT USAGE ON DATABASE FLEET_INTELLIGENCE TO ROLE ROUTE_OPTIMIZATION_ROLE;
GRANT USAGE ON SCHEMA FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION TO ROLE ROUTE_OPTIMIZATION_ROLE;
GRANT ALL ON SCHEMA FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION TO ROLE ROUTE_OPTIMIZATION_ROLE;
GRANT USAGE ON WAREHOUSE ROUTING_WH TO ROLE ROUTE_OPTIMIZATION_ROLE;

-- ORS function access (required for optimization)
GRANT USAGE ON DATABASE OPENROUTESERVICE_APP TO ROLE ROUTE_OPTIMIZATION_ROLE;
GRANT USAGE ON SCHEMA OPENROUTESERVICE_APP.CORE TO ROLE ROUTE_OPTIMIZATION_ROLE;
GRANT USAGE ON FUNCTION OPENROUTESERVICE_APP.CORE._OPTIMIZATION_RAW(VARIANT, VARCHAR) TO ROLE ROUTE_OPTIMIZATION_ROLE;
GRANT USAGE ON FUNCTION OPENROUTESERVICE_APP.CORE._DIRECTIONS_RAW(VARCHAR, VARIANT, VARCHAR) TO ROLE ROUTE_OPTIMIZATION_ROLE;
GRANT USAGE ON FUNCTION OPENROUTESERVICE_APP.CORE.ORS_STATUS(VARCHAR) TO ROLE ROUTE_OPTIMIZATION_ROLE;
GRANT USAGE ON FUNCTION OPENROUTESERVICE_APP.CORE.ORS_STATUS() TO ROLE ROUTE_OPTIMIZATION_ROLE;

-- ORS service management (allows OPTIMIZE_ROUTES to auto-resume suspended services)
GRANT MONITOR, OPERATE ON ALL SERVICES IN SCHEMA OPENROUTESERVICE_APP.CORE TO ROLE ROUTE_OPTIMIZATION_ROLE;

-- BIND SERVICE ENDPOINT for public SPCS app
GRANT BIND SERVICE ENDPOINT ON ACCOUNT TO ROLE ROUTE_OPTIMIZATION_ROLE;

-- Grant role to current user
GRANT ROLE ROUTE_OPTIMIZATION_ROLE TO USER IDENTIFIER(CURRENT_USER());

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. COMPUTE POOL (for web app)
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE COMPUTE POOL IF NOT EXISTS ROUTE_OPTIMIZATION_POOL
  MIN_NODES = 1
  MAX_NODES = 1
  INSTANCE_FAMILY = CPU_X64_XS
  AUTO_SUSPEND_SECS = 3600
  AUTO_RESUME = TRUE;

GRANT USAGE, MONITOR ON COMPUTE POOL ROUTE_OPTIMIZATION_POOL TO ROLE ROUTE_OPTIMIZATION_ROLE;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. NETWORK RULE + EXTERNAL ACCESS INTEGRATION (map tiles for app)
-- ═══════════════════════════════════════════════════════════════════════════════

USE DATABASE FLEET_INTELLIGENCE;
USE SCHEMA ROUTE_OPTIMIZATION;

CREATE OR REPLACE NETWORK RULE MAP_TILES_RULE
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = (
    'a.basemaps.cartocdn.com:443',
    'b.basemaps.cartocdn.com:443',
    'c.basemaps.cartocdn.com:443',
    'd.basemaps.cartocdn.com:443'
  );

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION MAP_TILES_EAI
  ALLOWED_NETWORK_RULES = (FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION.MAP_TILES_RULE)
  ENABLED = TRUE;

GRANT USAGE ON INTEGRATION MAP_TILES_EAI TO ROLE ROUTE_OPTIMIZATION_ROLE;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. IMAGE REPOSITORY (for Docker app image)
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE IMAGE REPOSITORY IF NOT EXISTS FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION.IMAGES;
GRANT READ, WRITE ON IMAGE REPOSITORY FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION.IMAGES TO ROLE ROUTE_OPTIMIZATION_ROLE;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. TABLES
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS PRODUIT (
    NOM             VARCHAR,         -- Product name (e.g. GNR, SP95)
    IDX             NUMBER(38,0),    -- Numeric index for arrays
    INCOMPATIBLE    VARCHAR          -- Comma-separated list of incompatible product names (or NULL)
);

-- Seed product reference data
MERGE INTO PRODUIT t USING (
    SELECT column1 AS NOM, column2 AS IDX, column3 AS INCOMPATIBLE FROM VALUES
    ('GNR', 0, NULL),
    ('Traction Force Plus', 1, NULL),
    ('Gazole', 2, NULL),
    ('Fioul Domestique', 3, NULL),
    ('HVO Non Routier', 4, NULL),
    ('HVO Routier', 5, NULL),
    ('SP95', 6, 'GNR,Traction Force Plus,Gazole,Fioul Domestique,HVO Non Routier,HVO Routier,Gazole Plus'),
    ('Gazole Plus', 7, NULL)
) s ON t.NOM = s.NOM
WHEN NOT MATCHED THEN INSERT (NOM, IDX, INCOMPATIBLE) VALUES (s.NOM, s.IDX, s.INCOMPATIBLE);

CREATE TABLE IF NOT EXISTS DEPOT (
    NO_DEPOT    NUMBER(38,0),
    NOM         VARCHAR,
    VILLE       VARCHAR,
    ADRESSE     VARCHAR,
    CP          VARCHAR,
    LON         FLOAT,
    LAT         FLOAT,
    ZONE        VARCHAR
);

CREATE TABLE IF NOT EXISTS CAMION (
    CAMNUM          VARCHAR,
    TYPECAMION      VARCHAR,
    IMMAT           VARCHAR,
    DEPOT_ORIGINE   NUMBER(38,0),
    NB_CUVES        NUMBER(38,0),
    CAPACITE_TOTALE NUMBER(38,0)
);

CREATE TABLE IF NOT EXISTS CAPACITE_CAMION (
    CAMNUM      VARCHAR,
    NUM_CUVE    NUMBER(38,0),
    CAPCUVE     NUMBER(38,0)
);

CREATE TABLE IF NOT EXISTS COMMANDES (
    ID_COMMANDE      VARCHAR,
    CLIENT           VARCHAR,
    LIEU_LIVRAISON   VARCHAR,
    ADRESSE          VARCHAR,
    VILLE            VARCHAR,
    CP               VARCHAR,
    LON              FLOAT,
    LAT              FLOAT,
    PRODUIT          VARCHAR,
    QTE_LITRES       NUMBER(38,0),
    HEURE_LIVRAISON  VARCHAR,
    DEPOT_CHARGEMENT NUMBER(38,0),
    ZONE             VARCHAR
);

CREATE TABLE IF NOT EXISTS OPTIMIZATION_RESULTS (
    RUN_ID           VARCHAR,
    VEHICLE          NUMBER(38,0),
    DURATION         NUMBER(38,0),
    RESPONSE         VARIANT,
    CHALLENGE        VARIANT,
    VENTILATION      VARIANT,
    NB_ITERATIONS    NUMBER(38,0),
    CREATED_AT       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 7. VIEWS
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW ROUTE_METRICS AS
WITH deduplicated AS (
    SELECT RESPONSE FROM OPTIMIZATION_RESULTS
    WHERE RUN_ID = (SELECT RUN_ID FROM OPTIMIZATION_RESULTS ORDER BY CREATED_AT DESC LIMIT 1)
    QUALIFY ROW_NUMBER() OVER (ORDER BY VEHICLE) = 1
),
route_steps AS (
    SELECT r.value:vehicle::INT AS vehicle_id, r.value:description::STRING AS vehicle_description,
        r.value:duration::INT AS duree_conduite_sec, r.value:service::INT AS service_total_sec,
        COALESCE(r.value:waiting_time::INT, 0) AS attente_sec,
        r.value:steps[0]:arrival::INT AS heure_depart_sec,
        r.value:steps[ARRAY_SIZE(r.value:steps)-1]:arrival::INT AS heure_retour_sec,
        r.value:steps[ARRAY_SIZE(r.value:steps)-1]:arrival::INT - r.value:steps[0]:arrival::INT AS duree_totale_sec,
        r.value:geometry AS geometry, r.value:steps AS steps
    FROM deduplicated o, LATERAL FLATTEN(input => o.RESPONSE:routes) r
),
route_jobs AS (
    SELECT rs.vehicle_id, COUNT(*) AS nb_livraisons
    FROM route_steps rs, LATERAL FLATTEN(input => rs.steps) s
    WHERE s.value:type::STRING = 'job' GROUP BY rs.vehicle_id
),
route_points AS (
    SELECT rs.vehicle_id, g.index AS pt_idx, g.value[0]::FLOAT AS lng, g.value[1]::FLOAT AS lat
    FROM route_steps rs, LATERAL FLATTEN(input => rs.geometry) g
),
segments AS (
    SELECT vehicle_id, ST_DISTANCE(ST_MAKEPOINT(lng, lat),
        ST_MAKEPOINT(LEAD(lng) OVER (PARTITION BY vehicle_id ORDER BY pt_idx),
                     LEAD(lat) OVER (PARTITION BY vehicle_id ORDER BY pt_idx))) AS segment_m
    FROM route_points
),
route_distances AS (
    SELECT vehicle_id, ROUND(SUM(segment_m) / 1000.0, 2) AS distance_km
    FROM segments WHERE segment_m IS NOT NULL GROUP BY vehicle_id
)
SELECT rs.vehicle_id, rs.vehicle_description, rs.duree_conduite_sec, rs.service_total_sec,
    rs.attente_sec, rs.duree_totale_sec, rs.heure_depart_sec, rs.heure_retour_sec,
    COALESCE(rj.nb_livraisons, 0) AS nb_livraisons, COALESCE(rd.distance_km, 0) AS distance_km,
    ROUND(COALESCE(rd.distance_km, 0) / NULLIF(rj.nb_livraisons, 0), 2) AS km_par_livraison,
    ROUND(COALESCE(rd.distance_km, 0) / NULLIF(rs.duree_conduite_sec / 3600.0, 0), 1) AS vitesse_moy_kmh
FROM route_steps rs LEFT JOIN route_jobs rj ON rs.vehicle_id = rj.vehicle_id
LEFT JOIN route_distances rd ON rs.vehicle_id = rd.vehicle_id;

CREATE OR REPLACE VIEW ROUTE_KPI AS
WITH unassigned_count AS (
    SELECT ARRAY_SIZE(RESPONSE:unassigned) AS nb_non_assignees
    FROM OPTIMIZATION_RESULTS
    WHERE RUN_ID = (SELECT RUN_ID FROM OPTIMIZATION_RESULTS ORDER BY CREATED_AT DESC LIMIT 1)
    QUALIFY ROW_NUMBER() OVER (ORDER BY VEHICLE) = 1
)
SELECT COUNT(*) AS nb_vehicules, SUM(rm.nb_livraisons) AS total_livraisons,
    COALESCE(uc.nb_non_assignees, 0) AS nb_non_assignees,
    ROUND(SUM(rm.distance_km), 1) AS distance_totale_km,
    ROUND(AVG(rm.km_par_livraison), 1) AS km_par_livraison_moy,
    SUM(rm.duree_totale_sec) AS duree_totale_flotte_sec,
    ROUND(SUM(rm.duree_totale_sec) / 3600.0, 1) AS duree_totale_flotte_h,
    MAX(rm.duree_totale_sec) AS amplitude_max_sec,
    ROUND(MAX(rm.duree_totale_sec) / 3600.0, 1) AS amplitude_max_h,
    ROUND(SUM(rm.distance_km) / NULLIF(SUM(rm.duree_conduite_sec) / 3600.0, 0), 1) AS vitesse_moy_globale_kmh
FROM ROUTE_METRICS rm CROSS JOIN unassigned_count uc GROUP BY uc.nb_non_assignees;

GRANT SELECT ON VIEW ROUTE_METRICS TO ROLE ROUTE_OPTIMIZATION_ROLE;
GRANT SELECT ON VIEW ROUTE_KPI TO ROLE ROUTE_OPTIMIZATION_ROLE;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 8. SEMANTIC VIEW + CORTEX AGENT
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE SEMANTIC VIEW ROUTES_ANALYTICS
  TABLES (
    commandes AS FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION.COMMANDES PRIMARY KEY (ID_COMMANDE) COMMENT = 'Commandes de livraison de carburant',
    depot AS FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION.DEPOT PRIMARY KEY (NO_DEPOT) COMMENT = 'Depots de chargement',
    camion AS FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION.CAMION PRIMARY KEY (CAMNUM) COMMENT = 'Flotte de camions-citernes',
    route_metrics AS FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION.ROUTE_METRICS PRIMARY KEY (VEHICLE_ID) COMMENT = 'Metriques par vehicule'
  )
  RELATIONSHIPS (
    commandes (DEPOT_CHARGEMENT) REFERENCES depot (NO_DEPOT),
    camion (DEPOT_ORIGINE) REFERENCES depot (NO_DEPOT)
  )
  FACTS (
    commandes.qte_litres AS QTE_LITRES,
    camion.capacite_totale AS CAPACITE_TOTALE,
    route_metrics.distance_km_val AS DISTANCE_KM,
    route_metrics.nb_livraisons_val AS NB_LIVRAISONS
  )
  DIMENSIONS (
    commandes.client AS CLIENT WITH SYNONYMS = ('nom client') COMMENT = 'Nom du client',
    commandes.ville AS VILLE COMMENT = 'Ville de livraison',
    commandes.produit AS PRODUIT WITH SYNONYMS = ('type produit', 'carburant') COMMENT = 'Produit petrolier',
    commandes.zone AS ZONE WITH SYNONYMS = ('region') COMMENT = 'Zone: IDF ou PICARDIE',
    depot.nom_depot AS NOM COMMENT = 'Nom du depot',
    depot.ville_depot AS depot.VILLE COMMENT = 'Ville du depot',
    camion.type_camion AS TYPECAMION COMMENT = 'Type: Porteur ou Semi',
    route_metrics.description_vehicule AS VEHICLE_DESCRIPTION COMMENT = 'Description vehicule'
  )
  METRICS (
    commandes.nombre_commandes AS COUNT(ID_COMMANDE) WITH SYNONYMS = ('nb commandes') COMMENT = 'Nombre total de commandes',
    commandes.volume_total_litres AS SUM(commandes.qte_litres) WITH SYNONYMS = ('volume total') COMMENT = 'Volume total en litres',
    camion.nombre_camions AS COUNT(CAMNUM) COMMENT = 'Nombre de camions',
    route_metrics.distance_totale AS SUM(route_metrics.distance_km_val) COMMENT = 'Distance totale km',
    route_metrics.total_livraisons AS SUM(route_metrics.nb_livraisons_val) COMMENT = 'Total livraisons',
    route_metrics.nombre_routes AS COUNT(VEHICLE_ID) COMMENT = 'Nombre de routes'
  )
  COMMENT = 'Analyse des tournees de livraison'
  AI_SQL_GENERATION 'Reponds en francais. Quantites en litres. Distances en km.'
  AI_QUESTION_CATEGORIZATION 'Rejette les questions non liees a la logistique ou aux livraisons.';

CREATE OR REPLACE AGENT ROUTES_AGENT
  COMMENT = 'Agent Cortex pour analyse des tournees de livraison'
  FROM SPECIFICATION
$$
models:
  orchestration: auto

instructions:
  response: "Tu es un assistant expert en logistique et optimisation de tournees pour un distributeur de produits petroliers. Reponds en francais, de maniere concise avec des chiffres precis."
  orchestration: "Utilise analyse_tournees pour toute question sur les commandes, vehicules, depots, distances ou resultats."

tools:
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "analyse_tournees"
      description: "Analyse donnees de tournees: commandes carburant, vehicules, depots, resultats optimisation, distances, volumes."

tool_resources:
  analyse_tournees:
    semantic_view: "FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION.ROUTES_ANALYTICS"
$$;

GRANT REFERENCES, SELECT ON SEMANTIC VIEW ROUTES_ANALYTICS TO ROLE ROUTE_OPTIMIZATION_ROLE;
GRANT USAGE ON AGENT ROUTES_AGENT TO ROLE ROUTE_OPTIMIZATION_ROLE;
