-- =============================================================================
-- 08_optimizer_sproc.sql
-- Deploys the route optimizer as a Snowpark Python Stored Procedure.
-- Uses NumPy arrays for ventilation (31x faster than dict+deepcopy).
-- After this, run: CALL OPTIMIZE_ROUTES('france', 5, TRUE);
--
-- REQUIRES: ROUTE_OPTIMIZATION_ROLE (no ACCOUNTADMIN needed)
-- USAGE: Deploy via Python connector (snow sql -f doesn't handle $$ in body):
--   See deploy skill Step 5 for exact commands.
-- =============================================================================

CREATE OR REPLACE PROCEDURE OPTIMIZE_ROUTES(
    REGION VARCHAR DEFAULT 'france',
    MAX_VEHICLES INT DEFAULT NULL,
    MULTI_TOUR BOOLEAN DEFAULT TRUE
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'numpy')
HANDLER = 'run'
EXECUTE AS CALLER
AS
$$
import json
import random
import uuid
import time
from math import radians, sin, cos, sqrt, atan2
import numpy as np

DD = chr(36) * 2  # dollar-dollar string delimiter for SQL

# --- Configuration ────────────────────────────────────────────────────────────
LOADING_TIME = 1800  # 30 min fixed loading/reloading time
UNASSIGNED_PENALTY_KM = 80
GA_POPULATION = 25
GA_GENERATIONS = 15
GA_ELITE = 3
GA_MUTATION_RATE = 0.3
GA_STAGNATION_LIMIT = 4
GA_IMMIGRATION = 2

WORKDAY_START = 21600    # 6h
MAX_WORK_HOURS = 8
WORKDAY_END = WORKDAY_START + MAX_WORK_HOURS * 3600  # 14h = 50400

MAX_CUVES = 5
EMPTY = -1

# Populated at runtime from PRODUIT table
PRODUCT_INDEX = {}
PRODUCT_NAMES = []
NUM_PRODUCTS = 0
COMPAT_MATRIX = None

session = None
region = None

def _load_produits():
    """Load product definitions from PRODUIT table and build compatibility matrix."""
    global PRODUCT_INDEX, PRODUCT_NAMES, NUM_PRODUCTS, COMPAT_MATRIX
    rows = _sql("SELECT NOM, IDX, INCOMPATIBLE FROM PRODUIT ORDER BY IDX")
    PRODUCT_INDEX = {r[0]: int(r[1]) for r in rows}
    PRODUCT_NAMES = [r[0] for r in rows]
    NUM_PRODUCTS = len(PRODUCT_NAMES)
    COMPAT_MATRIX = np.ones((NUM_PRODUCTS, NUM_PRODUCTS), dtype=np.bool_)
    for r in rows:
        if r[2]:  # INCOMPATIBLE column
            pid = int(r[1])
            for incompat_name in r[2].split(','):
                incompat_name = incompat_name.strip()
                if incompat_name in PRODUCT_INDEX:
                    other = PRODUCT_INDEX[incompat_name]
                    COMPAT_MATRIX[pid, other] = False
                    COMPAT_MATRIX[other, pid] = False

# ─── Haversine ────────────────────────────────────────────────────────────────
def _haversine_km(lon1, lat1, lon2, lat2):
    R = 6371.0
    dlat = radians(lat2 - lat1)
    dlon = radians(lon2 - lon1)
    a = sin(dlat/2)**2 + cos(radians(lat1))*cos(radians(lat2))*sin(dlon/2)**2
    return R * 2 * atan2(sqrt(a), sqrt(1 - a))

def calc_route_distance_km(geometry):
    if not geometry or len(geometry) < 2:
        return 0.0
    total = 0.0
    for i in range(len(geometry) - 1):
        total += _haversine_km(geometry[i][0], geometry[i][1], geometry[i+1][0], geometry[i+1][1])
    return total

# ─── Data loading ─────────────────────────────────────────────────────────────
def _sql(query):
    return session.sql(query).collect()

def _load_depots():
    rows = _sql("SELECT NO_DEPOT, NOM, VILLE, LON, LAT, ZONE FROM DEPOT")
    return {r[0]: {"nom": r[1], "ville": r[2], "lon": float(r[3]), "lat": float(r[4]), "zone": r[5]} for r in rows}

def _load_camions():
    rows = _sql("""
        SELECT c.CAMNUM, c.TYPECAMION, c.DEPOT_ORIGINE, c.CAPACITE_TOTALE,
               ARRAY_AGG(OBJECT_CONSTRUCT('num_cuve', cc.NUM_CUVE, 'capcuve', cc.CAPCUVE))
               WITHIN GROUP (ORDER BY cc.NUM_CUVE)
        FROM CAMION c JOIN CAPACITE_CAMION cc ON c.CAMNUM = cc.CAMNUM
        GROUP BY c.CAMNUM, c.TYPECAMION, c.DEPOT_ORIGINE, c.CAPACITE_TOTALE ORDER BY c.CAMNUM
    """)
    camions = []
    for r in rows:
        cuves = json.loads(r[4]) if isinstance(r[4], str) else r[4]
        camions.append({
            "camnum": r[0], "type": r[1], "depot": r[2], "capacite_totale": r[3],
            "cuves": [{"num": int(c["num_cuve"]), "cap": int(c["capcuve"])} for c in cuves],
        })
    return camions

def _load_commandes():
    rows = _sql("""
        SELECT ID_COMMANDE, CLIENT, LIEU_LIVRAISON, VILLE, LON, LAT,
               PRODUIT, QTE_LITRES, HEURE_LIVRAISON, DEPOT_CHARGEMENT, ZONE
        FROM COMMANDES ORDER BY ID_COMMANDE
    """)
    return [{"id": r[0], "client": r[1], "lieu": r[2], "ville": r[3],
             "lon": float(r[4]), "lat": float(r[5]), "produit": r[6], "qte": int(r[7]),
             "heure": r[8], "depot": int(r[9]), "zone": r[10]} for r in rows]

# ─── Static metadata (built once) ────────────────────────────────────────────
def _build_static(camions):
    """Build static NumPy arrays from camion data (caps, depots)."""
    n = len(camions)
    cuve_caps = np.zeros((n, MAX_CUVES), dtype=np.int32)
    cam_depots = np.zeros(n, dtype=np.int32)
    for i, cam in enumerate(camions):
        cam_depots[i] = cam["depot"]
        for j, cuve in enumerate(cam["cuves"][:MAX_CUVES]):
            cuve_caps[i, j] = cuve["cap"]
    return cuve_caps, cam_depots

# ─── VROOM call ───────────────────────────────────────────────────────────────
def _run_optimization_raw(vroom_json):
    json_str = json.dumps(vroom_json, ensure_ascii=False).replace(DD, "$ $")
    region_arg = f"'{region}'" if region else "NULL"
    row = _sql(f"SELECT OPENROUTESERVICE_APP.CORE._OPTIMIZATION_RAW(PARSE_JSON({DD}{json_str}{DD}), {region_arg})::VARCHAR")
    return json.loads(row[0][0])

# ─── Ventilation (NumPy) ─────────────────────────────────────────────────────
def _is_compatible(vent_row, j, pid):
    """Check if assigning product pid to physical cuve j is compatible with neighbors."""
    if j > 0:
        left = int(vent_row[j - 1])
        if left >= 0 and not COMPAT_MATRIX[pid, left]:
            return False
    if j < MAX_CUVES - 1:
        right = int(vent_row[j + 1])
        if right >= 0 and not COMPAT_MATRIX[pid, right]:
            return False
    return True

def _create_ventilation_np(camions, commandes, cuve_caps, cam_depots, priority_fn):
    """Create a ventilation as NumPy array using priority function.
    Each camion sees the full depot demand — this is intentional because multiple
    camions may be needed to cover all demand. VROOM decides which ones actually run."""
    n = len(camions)
    vent = np.full((n, MAX_CUVES), EMPTY, dtype=np.int8)
    depot_demand = {}
    for cmd in commandes:
        depot_demand.setdefault(cmd["depot"], {}).setdefault(cmd["produit"], 0)
        depot_demand[cmd["depot"]][cmd["produit"]] += cmd["qte"]

    for i, cam in enumerate(camions):
        demand = dict(depot_demand.get(cam["depot"], {}))
        products = priority_fn(demand, cam)
        cuves_sorted = sorted(range(len(cam["cuves"][:MAX_CUVES])),
                              key=lambda j: -cuve_caps[i, j])
        for j in cuves_sorted:
            if cuve_caps[i, j] == 0:
                continue
            assigned = None
            for prod in products:
                if demand.get(prod, 0) <= 0:
                    continue
                pid = PRODUCT_INDEX.get(prod, -1)
                if pid >= 0 and _is_compatible(vent[i], j, pid):
                    assigned = pid
                    break
            if assigned is not None:
                vent[i, j] = assigned
                demand[PRODUCT_NAMES[assigned]] -= cuve_caps[i, j]
                products = priority_fn(demand, cam)
    return vent

def _generate_population_np(camions, commandes, cuve_caps, cam_depots, size):
    """Generate initial population as list of NumPy arrays."""
    population = []
    population.append(_create_ventilation_np(camions, commandes, cuve_caps, cam_depots,
        lambda d, c: sorted([p for p, v in d.items() if v > 0], key=lambda p: -d.get(p, 0))))
    population.append(_create_ventilation_np(camions, commandes, cuve_caps, cam_depots,
        lambda d, c: sorted([p for p, v in d.items() if v > 0], key=lambda p: d.get(p, 0))))
    cmd_counts = {}
    for cmd in commandes:
        cmd_counts[cmd["produit"]] = cmd_counts.get(cmd["produit"], 0) + 1
    population.append(_create_ventilation_np(camions, commandes, cuve_caps, cam_depots,
        lambda d, c: sorted([p for p, v in d.items() if v > 0], key=lambda p: -cmd_counts.get(p, 0))))
    for i in range(size - len(population)):
        random.seed(i * 7 + 13)
        population.append(_create_ventilation_np(camions, commandes, cuve_caps, cam_depots,
            lambda d, c: sorted([p for p, v in d.items() if v > 0], key=lambda p: random.random())))
    return population

def _crossover_np(p1, p2):
    """Crossover: pick each camion row from p1 or p2."""
    mask = np.random.random(len(p1)) < 0.5
    return np.where(mask[:, None], p1, p2)

def _mutate_np(vent, cuve_caps, depot_products, camion_weights=None):
    """Mutate: swap products or reassign a cuve. Respects adjacency compatibility.
    If camion_weights provided, bias mutation toward poorly performing camions."""
    v = vent.copy()
    n = len(v)
    if camion_weights is not None and random.random() < 0.7:
        i = random.choices(range(n), weights=camion_weights, k=1)[0]
    else:
        i = random.randint(0, n - 1)
    filled = []
    for j in range(MAX_CUVES):
        if v[i, j] >= 0 and cuve_caps[i, j] > 0:
            filled.append(j)
    if not filled:
        return v
    if len(filled) >= 2 and random.random() < 0.5:
        a, b = random.sample(filled, 2)
        # Check compatibility after swap
        pid_a, pid_b = int(v[i, a]), int(v[i, b])
        v[i, a], v[i, b] = pid_b, pid_a
        if not _is_compatible(v[i], a, pid_b) or not _is_compatible(v[i], b, pid_a):
            v[i, a], v[i, b] = pid_a, pid_b  # revert
    else:
        j = random.choice(filled)
        available = [p for p in depot_products.get(i, []) if _is_compatible(v[i], j, p)]
        if available:
            v[i, j] = random.choice(available)
    return v

# ─── VROOM JSON builder (reads NumPy ventilation) ─────────────────────────────
def _build_vroom_json_np(camions, commandes, depots, vent, cuve_caps, max_vehicles):
    """Build VROOM JSON from NumPy ventilation array."""
    vehicles = []
    vehicle_id = 1
    meta = {}
    active_depots = set(cmd["depot"] for cmd in commandes)
    active_camions_idx = [i for i, c in enumerate(camions) if c["depot"] in active_depots]
    if max_vehicles:
        active_camions_idx = active_camions_idx[:max_vehicles]
    for idx in active_camions_idx:
        cam = camions[idx]
        depot = depots[cam["depot"]]
        capacity = [0] * NUM_PRODUCTS
        for j in range(MAX_CUVES):
            pid = int(vent[idx, j])
            if 0 <= pid < NUM_PRODUCTS and cuve_caps[idx, j] > 0:
                capacity[pid] += int(cuve_caps[idx, j])
        vehicles.append({
            "id": vehicle_id, "profile": "driving-hgv",
            "description": f"{cam['camnum']} ({cam['type']}) - {depot['ville']}",
            "start": [depot["lon"], depot["lat"]], "end": [depot["lon"], depot["lat"]],
            "capacity": capacity, "time_window": [WORKDAY_START + LOADING_TIME, WORKDAY_END],
        })
        meta[vehicle_id] = {"camnum": cam["camnum"], "tour": 1}
        vehicle_id += 1
    jobs = []
    for i, cmd in enumerate(commandes):
        amount = [0] * NUM_PRODUCTS
        if cmd["produit"] in PRODUCT_INDEX:
            amount[PRODUCT_INDEX[cmd["produit"]]] = cmd["qte"]
        service = max(300, int(cmd["qte"] / 1000 * 300))
        tw = [WORKDAY_START, WORKDAY_END]
        if cmd["heure"]:
            try:
                h = int(cmd["heure"])
                tw = [(h//100)*3600 + (h%100)*60, (h//100)*3600 + (h%100)*60 + 7200]
            except (ValueError, TypeError):
                pass
        jobs.append({"id": i+1, "description": f"{cmd['client']} - {cmd['ville']} ({cmd['produit']} {cmd['qte']}L)",
                     "location": [cmd["lon"], cmd["lat"]], "amount": amount, "service": service, "time_windows": [tw]})
    return {"vehicles": vehicles, "jobs": jobs}, meta

# ─── Evaluation ───────────────────────────────────────────────────────────────
def _evaluate(camions, commandes, depots, vent, cuve_caps, max_vehicles, multi_tour):
    vroom_json, meta = _build_vroom_json_np(camions, commandes, depots, vent, cuve_caps, max_vehicles)
    result = _run_optimization_raw(vroom_json)
    if result.get("code") != 0:
        return None
    routes = result.get("routes", [])
    unassigned = result.get("unassigned", [])
    combined_json = vroom_json
    final_result = result

    # Track per-vehicle ventilation for Tour 2+ (vehicle_id → cuves list)
    tour_ventilations = {}

    if multi_tour and len(unassigned) > 0:
        active_depots_set = set(cmd["depot"] for cmd in commandes)
        active_camions = [c for c in camions if c["depot"] in active_depots_set]
        if max_vehicles:
            active_camions = active_camions[:max_vehicles]
        end_times = {}
        for route in routes:
            steps = route.get("steps", [])
            if steps:
                end_times[route.get("vehicle")] = steps[-1].get("arrival", WORKDAY_END)
        # Build inverse lookup: camnum -> tour 1 vehicle_id
        camnum_to_vid = {m["camnum"]: vid for vid, m in meta.items() if m["tour"] == 1}
        all_extra = []
        tour_number = 2
        tour_id_base = 100
        while len(unassigned) > 0 and tour_number <= 5:
            unassigned_demand = {}
            for u in unassigned:
                job = next((j for j in vroom_json["jobs"] if j["id"] == u.get("id")), None)
                if job:
                    for pidx, amt in enumerate(job["amount"]):
                        if amt > 0:
                            unassigned_demand[PRODUCT_NAMES[pidx]] = unassigned_demand.get(PRODUCT_NAMES[pidx], 0) + amt
            if not unassigned_demand:
                break
            tour_vehicles = []
            for cam in active_camions:
                cam_vid = camnum_to_vid.get(cam["camnum"])
                if cam_vid is None:
                    continue
                return_time = end_times.get(cam_vid, 36000)
                tour_start = int(return_time + LOADING_TIME)
                if tour_start >= WORKDAY_END:
                    continue
                depot = depots[cam["depot"]]
                capacity = [0] * NUM_PRODUCTS
                local_demand = dict(unassigned_demand)
                cuve_assignments = []  # Track per-cuve product for this tour
                cuves_by_cap = sorted(enumerate(cam["cuves"][:MAX_CUVES]), key=lambda x: -x[1]["cap"])
                tour_vent = np.full(MAX_CUVES, EMPTY, dtype=np.int8)
                for idx, cuve in cuves_by_cap:
                    assigned = None
                    for prod in sorted(local_demand, key=lambda p: -local_demand.get(p, 0)):
                        if local_demand.get(prod, 0) <= 0:
                            continue
                        pid = PRODUCT_INDEX.get(prod, -1)
                        if pid >= 0 and _is_compatible(tour_vent, idx, pid):
                            assigned = prod
                            break
                    if assigned and assigned in PRODUCT_INDEX:
                        tour_vent[idx] = PRODUCT_INDEX[assigned]
                        capacity[PRODUCT_INDEX[assigned]] += cuve["cap"]
                        local_demand[assigned] -= cuve["cap"]
                        cuve_assignments.append({"num_cuve": cuve["num"], "cap": cuve["cap"], "produit": assigned})
                    else:
                        cuve_assignments.append({"num_cuve": cuve["num"], "cap": cuve["cap"], "produit": None})
                if sum(capacity) > 0:
                    actual_start = tour_start
                    if actual_start >= WORKDAY_END:
                        continue
                    tour_vid = tour_id_base + len(tour_vehicles)
                    tour_vehicles.append({
                        "id": tour_vid, "profile": "driving-hgv",
                        "description": f"{cam['camnum']} ({cam['type']}) - {depot['ville']} [Tour {tour_number}]",
                        "start": [depot["lon"], depot["lat"]], "end": [depot["lon"], depot["lat"]],
                        "capacity": capacity, "time_window": [actual_start, WORKDAY_END],
                    })
                    meta[tour_vid] = {"camnum": cam["camnum"], "tour": tour_number}
                    # Store ventilation for this tour
                    tour_ventilations[tour_vid] = cuve_assignments
            if not tour_vehicles:
                break
            unassigned_ids = set(u.get("id") for u in unassigned)
            tour_jobs = [j for j in vroom_json["jobs"] if j["id"] in unassigned_ids]
            if not tour_jobs:
                break
            r_tour = _run_optimization_raw({"vehicles": tour_vehicles, "jobs": tour_jobs})
            if r_tour.get("code") != 0:
                break
            routes_tour = r_tour.get("routes", [])
            if not routes_tour:
                break
            for route in routes_tour:
                steps = route.get("steps", [])
                if steps:
                    cam_name = meta.get(route.get("vehicle"), {}).get("camnum")
                    if cam_name:
                        orig = camnum_to_vid.get(cam_name)
                        if orig:
                            end_times[orig] = steps[-1].get("arrival", WORKDAY_END)
            routes = routes + routes_tour
            unassigned = r_tour.get("unassigned", [])
            all_extra.extend(tour_vehicles)
            if len(r_tour.get("unassigned", [])) == len(unassigned_ids):
                break
            tour_id_base += 100
            tour_number += 1
        final_result = dict(result)
        final_result["routes"] = routes
        final_result["unassigned"] = unassigned
        combined_json = {"vehicles": vroom_json["vehicles"] + all_extra, "jobs": vroom_json["jobs"]}

    total_km = sum(calc_route_distance_km(r.get("geometry", [])) for r in routes)
    nb_unassigned = len(unassigned)
    return {
        "score": total_km + nb_unassigned * UNASSIGNED_PENALTY_KM,
        "total_km": total_km, "nb_routes": len(routes), "nb_unassigned": nb_unassigned,
        "vroom_json": combined_json, "result": final_result, "ventilation": vent,
        "tour_ventilations": tour_ventilations,
    }

# ─── GA ───────────────────────────────────────────────────────────────────────
def _extract_camion_weights(result, camions):
    """Build mutation weight vector from VROOM result: camions on longer routes get higher weight."""
    weights = [1.0] * len(camions)
    routes = result.get("routes", [])
    camnum_to_idx = {cam["camnum"]: i for i, cam in enumerate(camions)}
    for route in routes:
        desc = route.get("description", "")
        camnum = desc.split(" ")[0] if desc else ""
        idx = camnum_to_idx.get(camnum)
        if idx is not None:
            km = calc_route_distance_km(route.get("geometry", []))
            weights[idx] = max(km, 1.0)
    return weights

def _run_ga(camions, commandes, depots, cuve_caps, cam_depots, depot_products, max_vehicles, multi_tour):
    population = _generate_population_np(camions, commandes, cuve_caps, cam_depots, GA_POPULATION)
    total_evals = 0
    last_scored = []
    prev_best = float('inf')
    stagnation = 0
    camion_weights = None

    for gen in range(GA_GENERATIONS):
        scored = []
        for vent in population:
            res = _evaluate(camions, commandes, depots, vent, cuve_caps, max_vehicles, multi_tour)
            total_evals += 1
            if res:
                scored.append((res["score"], vent, res))
        if not scored:
            continue
        scored.sort(key=lambda x: x[0])
        last_scored = scored

        # Early stopping on convergence
        if scored[0][0] >= prev_best:
            stagnation += 1
        else:
            stagnation = 0
            prev_best = scored[0][0]
        if stagnation >= GA_STAGNATION_LIMIT:
            break

        # Extract weights for informed mutation from best result
        camion_weights = _extract_camion_weights(scored[0][2]["result"], camions)

        elite = [s[1] for s in scored[:GA_ELITE]]
        new_pop = list(elite)
        while len(new_pop) < GA_POPULATION - GA_IMMIGRATION:
            p1 = scored[random.randint(0, min(len(scored)-1, GA_POPULATION//2))][1]
            p2 = scored[random.randint(0, min(len(scored)-1, GA_POPULATION//2))][1]
            child = _crossover_np(p1, p2)
            if random.random() < GA_MUTATION_RATE:
                child = _mutate_np(child, cuve_caps, depot_products, camion_weights)
            new_pop.append(child)

        # Immigration: inject fresh random individuals to maintain diversity
        for _ in range(GA_IMMIGRATION):
            new_pop.append(_create_ventilation_np(camions, commandes, cuve_caps, cam_depots,
                lambda d, c: sorted([p for p, v in d.items() if v > 0], key=lambda p: random.random())))

        population = new_pop

    # Final: evaluate only non-elite children (elites already scored in last gen)
    final = [s[2] for s in last_scored[:GA_ELITE]] if last_scored else []
    for vent in population[GA_ELITE:]:
        res = _evaluate(camions, commandes, depots, vent, cuve_caps, max_vehicles, multi_tour)
        total_evals += 1
        if res:
            final.append(res)
    final.sort(key=lambda x: x["score"])
    return final[0] if final else None, total_evals

# ─── Build effective ventilation from VROOM results ──────────────────────────
def _effective_ventilation(route, camions, vent, cuve_caps, tour_ventilations, jobs_by_id):
    """Build ventilation showing only products actually delivered on this route.
    Fills cuves in order with the delivered products (biggest cuves first)."""
    vid = route.get("vehicle", 0)
    desc = route.get("description", "")
    camnum = desc.split(" ")[0] if desc else ""
    steps = route.get("steps", [])

    # Compute delivered volumes per product from VROOM job amounts
    delivered = {}  # product_name -> total litres delivered
    for step in steps:
        if step.get("type") != "job":
            continue
        job = jobs_by_id.get(step.get("id"))
        if job:
            for pidx, amt in enumerate(job["amount"]):
                if amt > 0:
                    prod = PRODUCT_NAMES[pidx]
                    delivered[prod] = delivered.get(prod, 0) + amt

    if not delivered:
        return {}

    # Get cuves for this camion (from Tour 2 tracked data or from camion definition)
    cam = next((c for c in camions if c["camnum"] == camnum), None)
    if not cam:
        return {}

    # Fill cuves with delivered products (biggest cuves first)
    # Each cuve is filled with exactly the volume to deliver, not the full cuve capacity
    cuves_sorted = sorted(cam["cuves"][:MAX_CUVES], key=lambda c: -c["cap"])
    remaining = dict(delivered)
    result_cuves = []
    for cuve in cuves_sorted:
        # Find the product with the most remaining volume
        best_prod = None
        best_vol = 0
        for prod, vol in remaining.items():
            if vol > best_vol:
                best_prod = prod
                best_vol = vol
        if best_prod and best_vol > 0:
            # Load only what we need to deliver (capped at cuve capacity)
            loaded = min(cuve["cap"], best_vol)
            result_cuves.append({"num_cuve": cuve["num"], "vol": loaded, "produit": best_prod})
            remaining[best_prod] -= loaded
            if remaining[best_prod] <= 0:
                del remaining[best_prod]
        else:
            result_cuves.append({"num_cuve": cuve["num"], "vol": 0, "produit": None})

    # Build key: use [Tour N] suffix for multi-tour vehicles
    if "Tour" in desc:
        tour_label = desc.split(" - ")[-1] if " - " in desc else ""
        vent_key = f"{camnum} {tour_label}".strip()
    else:
        vent_key = camnum

    return {vent_key: result_cuves}

# ─── Store results ────────────────────────────────────────────────────────────
def _store(best, camions, nb_iterations, cuve_caps):
    run_id = str(uuid.uuid4())
    routes = best["result"].get("routes", [])
    tour_ventilations = best.get("tour_ventilations", {})
    jobs_by_id = {j["id"]: j for j in best["vroom_json"].get("jobs", [])}

    challenge_json = json.dumps(best["vroom_json"], ensure_ascii=False).replace(DD, "$ $")
    response_json = json.dumps(best["result"], ensure_ascii=False).replace(DD, "$ $")

    for route in routes:
        vid = route.get("vehicle", 0)
        dur = route.get("duration", 0)

        # Effective ventilation: shows only products actually delivered on this route
        route_vent = _effective_ventilation(route, camions, best["ventilation"], cuve_caps, tour_ventilations, jobs_by_id)

        ventilation_json = json.dumps(route_vent, ensure_ascii=False).replace(DD, "$ $")
        session.sql(f"""
            INSERT INTO OPTIMIZATION_RESULTS (RUN_ID, VEHICLE, DURATION, RESPONSE, CHALLENGE, VENTILATION, NB_ITERATIONS)
            SELECT '{run_id}', {vid}, {dur},
                   PARSE_JSON({DD}{response_json}{DD}),
                   PARSE_JSON({DD}{challenge_json}{DD}),
                   PARSE_JSON({DD}{ventilation_json}{DD}),
                   {nb_iterations}
        """).collect()
    return run_id

# ─── Entry point ──────────────────────────────────────────────────────────────
def run(snowpark_session, p_region: str, p_max_vehicles: int, p_multi_tour: bool) -> str:
    global session, region
    session = snowpark_session
    region = p_region if p_region else None
    max_vehicles = p_max_vehicles if p_max_vehicles and p_max_vehicles > 0 else None

    # Set context
    session.sql("USE DATABASE FLEET_INTELLIGENCE").collect()
    session.sql("USE SCHEMA ROUTE_OPTIMIZATION").collect()

    # Ensure ORS services are running
    services_to_check = ['ROUTING_GATEWAY_SERVICE', 'VROOM_SERVICE']
    resumed_any = False
    for svc in services_to_check:
        fqn = f"OPENROUTESERVICE_APP.CORE.{svc}"
        rows = _sql(f"SHOW SERVICES LIKE '{svc}' IN SCHEMA OPENROUTESERVICE_APP.CORE")
        if rows:
            status = rows[0][1]  # status column
            if status == 'SUSPENDED':
                print(f"  Resuming {svc}...")
                session.sql(f"ALTER SERVICE {fqn} RESUME").collect()
                resumed_any = True

    # Wait for services to be running (up to 120s)
    if resumed_any:
        print("  Waiting for services to start...")
        time.sleep(10)  # initial grace period after resume
    for attempt in range(24):
        all_ready = True
        for svc in services_to_check:
            rows = _sql(f"SHOW SERVICES LIKE '{svc}' IN SCHEMA OPENROUTESERVICE_APP.CORE")
            if rows and rows[0][1] != 'RUNNING':
                all_ready = False
                break
        if all_ready:
            break
        time.sleep(5)
    else:
        return "ERROR: ORS services did not start within 120s. Check OPENROUTESERVICE_APP_COMPUTE_POOL status."

    # Verify ORS health
    if region:
        health = _sql(f"SELECT OPENROUTESERVICE_APP.CORE.ORS_STATUS('{region}'):service_ready::VARCHAR")
    else:
        health = _sql("SELECT OPENROUTESERVICE_APP.CORE.ORS_STATUS():service_ready::VARCHAR")
    if health[0][0] != 'true':
        return f"ERROR: ORS region '{region or 'default'}' not ready. Run PROVISION_REGION_WRAPPER first."

    depots = _load_depots()
    camions = _load_camions()
    commandes = _load_commandes()
    _load_produits()
    if not commandes:
        return "ERROR: No commandes in table"

    # Build static metadata
    cuve_caps, cam_depots = _build_static(camions)

    # Pre-compute available products per camion (for mutation)
    depot_products = {}
    depot_demand = {}
    for cmd in commandes:
        depot_demand.setdefault(cmd["depot"], set()).add(PRODUCT_INDEX.get(cmd["produit"], -1))
    for i, cam in enumerate(camions):
        prods = [p for p in depot_demand.get(cam["depot"], set()) if p >= 0]
        depot_products[i] = prods if prods else [0]

    # Run GA
    best, nb_iterations = _run_ga(camions, commandes, depots, cuve_caps, cam_depots, depot_products, max_vehicles, p_multi_tour)
    if not best:
        return "ERROR: GA produced no valid results"

    # Store
    run_id = _store(best, camions, nb_iterations, cuve_caps)

    return (f"OK: {best['total_km']:.0f} km | {best['nb_unassigned']} unassigned | "
            f"{best['nb_routes']} routes | {nb_iterations} evaluations | run_id={run_id}")
$$;

-- Grant execute to role
GRANT USAGE ON PROCEDURE OPTIMIZE_ROUTES(VARCHAR, INT, BOOLEAN) TO ROLE ROUTE_OPTIMIZATION_ROLE;
