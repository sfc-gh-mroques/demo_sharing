# Route Optimization — Fleet Intelligence

Optimisation de tournées de livraison multi-produits sur Snowflake.

Ce projet utilise un **algorithme génétique** pour trouver la meilleure affectation de produits aux cuves des camions (ventilation), puis appelle le solver VROOM via l'application native **OpenRouteService** pour calculer les tournées optimales.

Les résultats sont stockés dans Snowflake et visualisés dans une application Next.js déployée sur **Snowpark Container Services (SPCS)**.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Snowflake Account                         │
│                                                             │
│  ┌──────────────┐   ┌─────────────────────────────────┐    │
│  │   Tables     │   │  SPCS Web App (Next.js)          │    │
│  │  - DEPOT     │◄──│  - Dashboard / Carte / Planning  │    │
│  │  - CAMION    │   │  - Requête les tables + vues     │    │
│  │  - COMMANDES │   └─────────────────────────────────┘    │
│  │  - OPTIM.    │                                           │
│  │    RESULTS   │   ┌─────────────────────────────────┐    │
│  └──────────────┘   │  Views                           │    │
│         ▲           │  - ROUTE_METRICS (km exact)      │    │
│         │           │  - ROUTE_KPI (agrégats)          │    │
│  ┌──────┴───────┐   └─────────────────────────────────┘    │
│  │  Optimizer   │                                           │
│  │  (Python GA) │──► VROOM via ORS Native App              │
│  └──────────────┘                                           │
└─────────────────────────────────────────────────────────────┘
```

---

## Prérequis

| Outil | Version | Usage |
|-------|---------|-------|
| Snowflake Account | Enterprise+ | Support SPCS + Geospatial |
| SnowCLI (`snow`) | >= 3.0 | Déploiement, registry login |
| Docker | >= 20 | Build de l'image app |
| Python | >= 3.9 | Exécution de l'optimizer |
| Node.js | >= 20 | Développement local de l'app |
| Cortex Code (`cortex`) | Latest | Installation de l'app ORS |
| OpenRouteService App | Installée | Routing engine (VROOM) |

### Prérequis ORS — Installation via le repo officiel

L'optimizer utilise le moteur de routage OpenRouteService, déployé comme une app SPCS
sur votre compte Snowflake. L'installation se fait via le repo officiel et Cortex Code (CoCo).

**Repo :** `https://github.com/Snowflake-Labs/sfguide-Create-a-Route-Optimisation-and-Vehicle-Route-Plan-Simulator`

**Guide officiel :** `https://www.snowflake.com/en/developers/guides/oss-install-openrouteservice-native-app/`

**Installation (résumé) :**

```bash
# 1. Cloner le repo
git clone https://github.com/Snowflake-Labs/sfguide-Create-a-Route-Optimisation-and-Vehicle-Route-Plan-Simulator
cd sfguide-Create-a-Route-Optimisation-and-Vehicle-Route-Plan-Simulator

# 2. Lancer Cortex Code avec votre connexion
cortex -c <NOM_CONNEXION>

# 3. Dans CoCo, exécuter le skill de build
$build-routing-solution
```

CoCo va automatiquement :
- Créer la DB `OPENROUTESERVICE_APP`, les stages, le compute pool HIGHMEM
- Builder et push 5 images Docker (openrouteservice, downloader, gateway, vroom, control_app)
- Déployer les 5 services SPCS
- Charger les données seed (San Francisco par défaut)

**Si vous ne pouvez pas utiliser CoCo**, le skill est un fichier Markdown lisible :
`.cortex/skills/build-routing-solution/SKILL.md` — il décrit chaque étape SQL et bash
que vous pouvez exécuter manuellement.

**Vérification :**
```sql
-- Les 5 services doivent être RUNNING
SHOW SERVICES IN DATABASE OPENROUTESERVICE_APP;
-- La health check doit retourner true
SELECT OPENROUTESERVICE_APP.CORE.ORS_STATUS():service_ready;
```

---

## Structure du projet

```
route-optimization/
├── app/                  # Application Next.js (dashboard, carte, planning, chat agent)
├── data/sample/          # Données de démo anonymisées (IDF + Oise)
├── deploy/               # Build Docker + déploiement du service SPCS
├── scripts/              # Helper de déploiement de la procédure stockée
├── setup/
│   ├── setup.sql         # Infra : DB, rôle, compute pool, EAI, repo d'images, tables, vues, semantic view, agent
│   ├── load_data.sql     # Chargement des CSV de démo
│   └── optimizer_sproc.sql  # Procédure OPTIMIZE_ROUTES (algorithme génétique + VROOM)
├── .cortex/skills/       # Skills CoCo : $deploy et $deploy-ors
└── presentation.html     # Présentation de la solution
```

---

## Déploiement rapide (via Cortex Code)

```bash
cd route-optimization/
cortex -c <NOM_CONNEXION>
```

Puis dans CoCo : `$deploy`

CoCo lit `.cortex/skills/deploy/SKILL.md` et exécute chaque étape
(infrastructure, données, ORS, optimizer, app web) avec confirmation aux étapes clés.

> **Prérequis :** Docker lancé et app ORS installée sur le compte (voir ci-dessus).

---

## Déploiement pas à pas (sans CoCo)

Toutes les commandes s'exécutent **depuis la racine du projet**.

### 1. Configuration Snowflake CLI

```bash
snow connection test --connection <NOM_CONNEXION>
snow sql -q "SELECT CURRENT_ACCOUNT_LOCATOR()" --connection <NOM_CONNEXION>
```

### 2. Infrastructure Snowflake (ACCOUNTADMIN)

```bash
snow sql -f setup/setup.sql --connection <NOM_CONNEXION>
```

Crée la base `FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION`, le warehouse `ROUTING_WH`, le rôle
`ROUTE_OPTIMIZATION_ROLE`, le compute pool, l'EAI pour les tuiles de carte, le repo d'images,
les tables, les vues `ROUTE_METRICS` / `ROUTE_KPI`, la semantic view et l'agent `ROUTES_AGENT`.

> ORS doit être installé **avant** : le script donne des droits sur `OPENROUTESERVICE_APP`.

### 3. Provisionner la région de routage ORS

L'ORS est installé avec San Francisco par défaut. Il faut provisionner la carte France
pour couvrir l'ensemble des zones de livraison.

Le graphe est construit **une seule fois** puis persisté sur un stage Snowflake. Les
redémarrages ultérieurs du service chargent le graphe en ~1 min sans recalcul.

**Tout se fait en SQL — aucune dépendance locale :**

```sql
-- Provisionner la France entière (download 4GB + build graphe, ~2-4h la première fois)
-- La procédure fait tout : download → config → create service → wait for graph
CALL OPENROUTESERVICE_APP.CORE.PROVISION_REGION_WRAPPER(
    'job_france',                                                   -- job_id (libre)
    'france',                                                       -- nom de la région
    'France',                                                       -- display name
    'https://download.geofabrik.de/europe/france-latest.osm.pbf',   -- URL du PBF
    42.0, 51.5, -5.5, 8.5,                                         -- bbox (min_lat, max_lat, min_lon, max_lon)
    'driving-hgv'                                                   -- profil(s) de routage
);
```

Vérifier la progression :
```sql
-- Statut du job de provisioning
SELECT STATUS, STAGE, MESSAGE FROM OPENROUTESERVICE_APP.CORE.REGION_PROVISION_JOBS
WHERE JOB_ID = 'job_france';

-- Ou directement le health check de la région
SELECT OPENROUTESERVICE_APP.CORE.ORS_STATUS('france'):service_ready;
-- Attendre que ça retourne: true
```

**Alternative rapide pour tester** (IDF seul, ~320MB, ~15 min de build) :
```sql
CALL OPENROUTESERVICE_APP.CORE.PROVISION_REGION_WRAPPER(
    'job_idf', 'idf', 'Ile-de-France',
    'https://download.geofabrik.de/europe/france/ile-de-france-latest.osm.pbf',
    48.1, 49.2, 1.4, 3.6, 'driving-hgv'
);
```

> **Dimensionnement du compute pool ORS selon la carte :**
>
> | Carte | Taille PBF | RAM graphe | Compute Pool minimum | Build initial |
> |-------|-----------|-----------|---------------------|---------------|
> | Ville (Paris) | ~100MB | ~500MB | HIGHMEM_X64_S (16GB) | 5-10 min |
> | Région (IDF + Picardie) | ~320MB | ~1.5GB | HIGHMEM_X64_S (16GB) | 15-20 min |
> | France entière | ~4GB | ~8GB | **HIGHMEM_X64_M (32GB)** | 2-4h |
>
> Pour passer en France entière, augmenter le compute pool ORS :
> ```sql
> ALTER COMPUTE POOL OPENROUTESERVICE_APP_COMPUTE_POOL
>   SET INSTANCE_FAMILY = HIGHMEM_X64_M;
> ```
>
> **Note :** La taille de la carte n'affecte PAS la vitesse des calculs de routage.
> ORS utilise des Contraction Hierarchies (raccourcis pré-calculés) : un itinéraire
> Paris-Compiègne prend ~0.1 sec que ce soit sur la carte IDF ou France entière.
> Seul le build initial du graphe est plus long.

### 4. Charger les données de démo

```bash
snow sql -f setup/load_data.sql --connection <NOM_CONNEXION>
```

### 4bis. Déployer la procédure d'optimisation

Le corps Python de la procédure contient des `$$` : elle se déploie via le connecteur Python.

```bash
pip install snowflake-connector-python
python scripts/deploy_sproc.py --connection <NOM_CONNEXION>
```

### 5. Lancer l'optimisation

L'optimizer est déployé comme une **Stored Procedure Snowpark** — tout tourne dans Snowflake,
pas besoin de Python local.

```sql
-- Lancer l'optimisation (5 véhicules max, multi-tour activé)
-- Région 'idf' (ou 'france' si vous avez provisionné la France entière)
CALL OPTIMIZE_ROUTES('idf', 5, TRUE);

-- Ou sans limite de véhicules
CALL OPTIMIZE_ROUTES('idf', NULL, TRUE);
```

La procédure :
- Lit les tables `COMMANDES`, `DEPOT`, `CAMION`, `CAPACITE_CAMION`
- Exécute l'algorithme génétique (25 individus x 15 générations)
- Appelle VROOM via `OPENROUTESERVICE_APP.CORE._OPTIMIZATION_RAW`
- Stocke le meilleur résultat dans `OPTIMIZATION_RESULTS`
- Retourne un résumé : `"OK: 342 km | 8 unassigned | 5 routes | 375 evaluations"`

**Durée :** ~7-8 minutes (25 pop x 15 gen, 13 commandes IDF, 400 évaluations VROOM).
Pour un test rapide, réduire à 8 pop x 3 gen (~40 sec) en modifiant les constantes dans le stored proc.

### 6. Déployer l'application web

```bash
cd deploy/

./deploy.sh \
    --account-locator AB12345 \
    --database FLEET_INTELLIGENCE \
    --schema ROUTE_OPTIMIZATION \
    --connection <NOM_CONNEXION>
```

Le script :
1. Build l'image Docker
2. Se connecte au registry Snowflake
3. Push l'image
4. Génère la spec de service SPCS
5. Crée le service (drop + create pour forcer le pull)
6. Affiche l'URL de l'endpoint

### 7. Accéder au dashboard

L'URL est affichée à la fin du déploiement. Format :
```
https://<random>-<org>-<account>.snowflakecomputing.app
```

---

## Développement local

### App (Next.js)

```bash
cd app/
cp ../deploy/env.template .env.local
# Éditer .env.local avec vos credentials

npm install
npm run dev
# → http://localhost:3000
```

---

## Modèle de données

### Tables d'entrée

| Table | Description |
|-------|-------------|
| `DEPOT` | Dépôts pétroliers (localisation, zone) |
| `CAMION` | Flotte de camions-citernes (type, capacité, dépôt d'attache) |
| `CAPACITE_CAMION` | Détail des cuves par camion |
| `COMMANDES` | Commandes du jour à livrer (client, produit, quantité, contrainte horaire) |

### Table de sortie

| Table | Description |
|-------|-------------|
| `OPTIMIZATION_RESULTS` | Résultat VROOM complet (routes, géométrie, ventilation) |

### Vues analytiques

| Vue | Description |
|-----|-------------|
| `ROUTE_METRICS` | Métriques par véhicule : distance exacte (ST_DISTANCE), durée, nb livraisons |
| `ROUTE_KPI` | KPIs agrégés de la flotte : distance totale, km/livraison, vitesse moyenne |

---

## Troubleshooting

### L'app affiche "No optimization results found"
L'optimizer n'a pas encore été lancé. Exécuter :
```sql
CALL OPTIMIZE_ROUTES('idf', NULL, TRUE);
```

### Service SPCS ne démarre pas ("Failed to pull image")

**Cause la plus fréquente :** Docker Desktop produit des manifest lists OCI (avec provenance/SBOM)
que SPCS ne peut pas pull.

**Solution :** Toujours builder avec ces flags :
```bash
docker build --platform linux/amd64 --provenance=false --sbom=false -t <image> .
```

Le script `deploy.sh` inclut déjà ces flags. Si vous buildez manuellement, ne les oubliez pas.

Autres causes possibles — vérifier les logs :
```sql
SELECT SYSTEM$GET_SERVICE_LOGS('FLEET_INTELLIGENCE.ROUTE_OPTIMIZATION.ROUTE_OPTIMIZATION_APP', '0', 'app', 50);
```

### Format du chemin d'image dans la spec de service

La spec de service SPCS doit utiliser le **chemin interne** (sans le hostname du registry) :
```yaml
image: /fleet_intelligence/route_optimization/images/route-optimization-app:latest
```
PAS l'URL complète `<org>-<account>.registry.snowflakecomputing.com/...`.

### DNS resolution error (ENOTFOUND) dans SPCS
**Ne PAS** setter `SNOWFLAKE_HOST` manuellement dans la spec de service.
Le Node.js SDK auto-derive le bon hostname interne (qui inclut des segments
internes comme `prod3`) à partir du seul account locator. Setter le host
manuellement échoue quasi-systématiquement car le format interne SPCS est
imprévisible (ex: `<locator>.prod3.<region>.aws.snowflakecomputing.com`).

Solution : ne fournir que `SNOWFLAKE_ACCOUNT` avec le locator (ex: `AB12345`).

### Connection refused (port mismatch)
Le Dockerfile expose le port **8080**. La spec de service doit utiliser `port: 8080` dans les endpoints.

### ORS region not ready
Le build du graphe prend 15-20 minutes. Vérifier :
```sql
SELECT OPENROUTESERVICE_APP.CORE.ORS_STATUS('france'):service_ready;
```

### Points de livraison hors de la carte (VROOM code 3)
Si l'optimizer retourne "GA produced no valid results", c'est probablement que certaines
commandes ont des coordonnées hors de la couverture de la carte provisionnée.

Solutions :
- **Vérifier** les bounds de la carte : `SELECT OPENROUTESERVICE_APP.CORE.ORS_STATUS('france'):bounds_info;`
- **Filtrer** les commandes hors bounds avant de lancer l'optimisation :
  ```sql
  DELETE FROM COMMANDES WHERE LAT > 49.1 OR LAT < 48.0;  -- adapter aux bounds de votre carte
  ```
- **Provisionner une carte plus large** (France entière avec HIGHMEM_X64_M)

### Image non mise à jour après push
SPCS cache les images `latest`. Il faut `DROP SERVICE` puis `CREATE SERVICE` (c'est ce que fait le script deploy.sh).

---

## Référence Skills ORS (CoCo)

Le repo ORS (`sfguide-Create-a-Route-Optimisation-and-Vehicle-Route-Plan-Simulator`)
contient des **skills CoCo** — des fichiers Markdown structurés qui décrivent chaque
opération pas à pas. Ils sont utilisables via Cortex Code (`cortex`) mais aussi
**lisibles manuellement** comme documentation technique.

### Localisation des skills

```
<repo-ors>/.cortex/skills/
├── build-routing-solution/SKILL.md      # Installation complète ORS
├── routing-customization/SKILL.md       # Changement de carte / profils
│   ├── location/SKILL.md               # Sous-skill: changer la carte
│   └── routing-profiles/SKILL.md       # Sous-skill: changer les profils
├── route-optimization/SKILL.md          # Demo route optimization
├── routing-solution-cleanup/SKILL.md    # Nettoyage complet
└── ...
```

### Comment utiliser un skill

**Via CoCo (interactif) :**
```bash
cd <repo-ors>
cortex -c <NOM_CONNEXION>
# Puis dans CoCo:
$build-routing-solution
# ou
$routing-customization
```

**Manuellement (sans CoCo) :**
Ouvrir le fichier `SKILL.md` correspondant et exécuter chaque étape SQL/bash décrite.
Les skills contiennent les commandes exactes, les vérifications attendues, et les
instructions de troubleshooting.

### Skills clés pour ce projet

| Besoin | Skill | Fichier |
|--------|-------|---------|
| Installer ORS from scratch | `$build-routing-solution` | `.cortex/skills/build-routing-solution/SKILL.md` |
| Changer la carte géographique | `$routing-customization` | `.cortex/skills/routing-customization/SKILL.md` |
| Voir les fonctions SQL disponibles | — | `.cortex/skills/build-routing-solution/references/available-functions.md` |
| Troubleshooting ORS | — | `.cortex/skills/build-routing-solution/references/troubleshooting.md` |
| Tout supprimer | `$routing-solution-cleanup` | `.cortex/skills/routing-solution-cleanup/SKILL.md` |

### Fonctions SQL ORS utilisées par l'optimizer

```sql
-- Optimisation de routes (appel VROOM)
SELECT OPENROUTESERVICE_APP.CORE._OPTIMIZATION_RAW(
    PARSE_JSON('{"vehicles": [...], "jobs": [...]}'),
    'france'  -- nom de la région provisionnée
)::VARCHAR;

-- Vérification qu'un point est routable
SELECT OPENROUTESERVICE_APP.CORE._DIRECTIONS_RAW(
    'driving-hgv',
    PARSE_JSON('{"coordinates": [[lon1,lat1],[lon2,lat2]]}'),
    'france'
)::VARCHAR;

-- Health check
SELECT OPENROUTESERVICE_APP.CORE.ORS_STATUS('france'):service_ready;
```

---

## Paramètres de l'optimisation

| Paramètre | Valeur | Description |
|-----------|--------|-------------|
| `GA_POPULATION` | 25 | Taille de la population |
| `GA_GENERATIONS` | 15 | Nombre de générations |
| `GA_ELITE` | 3 | Individus conservés directement |
| `GA_MUTATION_RATE` | 0.3 | Probabilité de mutation |
| `LOADING_TIME_PER_1000L` | 180s | Temps de chargement (3 min/m3) |
| `RECHARGE_TIME` | 3600s | Pause entre deux tours |
| `UNASSIGNED_PENALTY_KM` | 80 km | Pénalité par commande non livrée |

> **Performance GA (NumPy) :** L'optimiseur utilise des **arrays NumPy** pour la
> ventilation, ce qui élimine les `copy.deepcopy` (gain 31x mesuré). Avec 25 pop x
> 15 gen sur 13 commandes IDF, l'optimisation prend **~7-8 min** (400 évaluations
> VROOM à ~1.1 sec chacune). Les appels VROOM (~0.2 sec) et le transport réseau
> dominent — le compute Python GA est négligeable grâce à NumPy.

Le départ des véhicules est fixé à **6h00 + temps de chargement** (soit ~6h25 pour un camion plein).
Les livraisons contraintes (colonne `HEURE_LIVRAISON`) créent une fenêtre de 2h à partir de l'heure indiquée.
