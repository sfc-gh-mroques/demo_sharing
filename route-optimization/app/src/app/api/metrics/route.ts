import { NextResponse } from 'next/server';
import { query } from '@/lib/snowflake';

export const dynamic = 'force-dynamic';

export async function GET() {
  try {
    const [kpiRows, routeRows] = await Promise.all([
      query('SELECT * FROM ROUTE_KPI'),
      query(`
        SELECT VEHICLE_ID, VEHICLE_DESCRIPTION, DUREE_CONDUITE_SEC, SERVICE_TOTAL_SEC,
               ATTENTE_SEC, DUREE_TOTALE_SEC, HEURE_DEPART_SEC, HEURE_RETOUR_SEC,
               NB_LIVRAISONS, DISTANCE_KM, KM_PAR_LIVRAISON, VITESSE_MOY_KMH
        FROM ROUTE_METRICS
        ORDER BY VEHICLE_ID
      `),
    ]);

    if (kpiRows.length === 0) {
      return NextResponse.json({ error: 'No metrics found' }, { status: 404 });
    }

    return NextResponse.json({
      kpi: {
        nb_vehicules: kpiRows[0].NB_VEHICULES,
        total_livraisons: kpiRows[0].TOTAL_LIVRAISONS,
        nb_non_assignees: kpiRows[0].NB_NON_ASSIGNEES,
        distance_totale_km: kpiRows[0].DISTANCE_TOTALE_KM,
        km_par_livraison_moy: kpiRows[0].KM_PAR_LIVRAISON_MOY,
        duree_totale_flotte_h: kpiRows[0].DUREE_TOTALE_FLOTTE_H,
        amplitude_max_h: kpiRows[0].AMPLITUDE_MAX_H,
        vitesse_moy_globale_kmh: kpiRows[0].VITESSE_MOY_GLOBALE_KMH,
      },
      routes: routeRows.map((r: any) => ({
        vehicle_id: r.VEHICLE_ID,
        vehicle_description: r.VEHICLE_DESCRIPTION,
        duree_conduite_sec: r.DUREE_CONDUITE_SEC,
        service_total_sec: r.SERVICE_TOTAL_SEC,
        attente_sec: r.ATTENTE_SEC,
        duree_totale_sec: r.DUREE_TOTALE_SEC,
        heure_depart_sec: r.HEURE_DEPART_SEC,
        heure_retour_sec: r.HEURE_RETOUR_SEC,
        nb_livraisons: r.NB_LIVRAISONS,
        distance_km: r.DISTANCE_KM,
        km_par_livraison: r.KM_PAR_LIVRAISON,
        vitesse_moy_kmh: r.VITESSE_MOY_KMH,
      })),
    });
  } catch (error: any) {
    console.error('Metrics API error:', error);
    return NextResponse.json({ error: error.message }, { status: 500 });
  }
}
