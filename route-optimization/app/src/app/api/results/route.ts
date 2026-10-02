import { NextResponse } from 'next/server';
import { query } from '@/lib/snowflake';

export const dynamic = 'force-dynamic';

export async function GET() {
  try {
    // Get the latest run's optimization result
    const mainRow = await query(`
      SELECT RESPONSE::VARCHAR as RESPONSE, CHALLENGE::VARCHAR as CHALLENGE, NB_ITERATIONS, RUN_ID
      FROM OPTIMIZATION_RESULTS
      WHERE RUN_ID = (SELECT RUN_ID FROM OPTIMIZATION_RESULTS ORDER BY CREATED_AT DESC LIMIT 1)
      LIMIT 1
    `);
    if (mainRow.length === 0) {
      return NextResponse.json({ error: 'No optimization results found' }, { status: 404 });
    }

    const latestRunId = mainRow[0].RUN_ID;

    // Get all ventilations for this run (per vehicle)
    const ventRows = await query(`
      SELECT VEHICLE, VENTILATION::VARCHAR as VENTILATION
      FROM OPTIMIZATION_RESULTS
      WHERE RUN_ID = '${latestRunId}'
      ORDER BY VEHICLE
    `);

    // Get physical cuve capacities from reference table
    const cuveRows = await query(`
      SELECT CAMNUM, NUM_CUVE, CAPCUVE FROM CAPACITE_CAMION
    `);
    // Build lookup: camnum -> num_cuve -> cap_max
    const cuveCaps: Record<string, Record<number, number>> = {};
    for (const row of cuveRows) {
      if (!cuveCaps[row.CAMNUM]) cuveCaps[row.CAMNUM] = {};
      cuveCaps[row.CAMNUM][row.NUM_CUVE] = row.CAPCUVE;
    }

    const response = typeof mainRow[0].RESPONSE === 'string'
      ? JSON.parse(mainRow[0].RESPONSE)
      : mainRow[0].RESPONSE;
    const challenge = typeof mainRow[0].CHALLENGE === 'string'
      ? JSON.parse(mainRow[0].CHALLENGE)
      : mainRow[0].CHALLENGE;

    // Build ventilation map and enrich with cap_max from CAPACITE_CAMION
    const ventilation: Record<string, any> = {};
    for (const row of ventRows) {
      if (row.VENTILATION) {
        const vMap = typeof row.VENTILATION === 'string'
          ? JSON.parse(row.VENTILATION)
          : row.VENTILATION;
        if (vMap && typeof vMap === 'object') {
          for (const [key, val] of Object.entries(vMap)) {
            if (Array.isArray(val)) {
              // key is camnum or "camnum City [Tour N]" — extract camnum (first word)
              const camnum = key.split(' ')[0];
              const enriched = (val as any[]).map((cuve: any) => ({
                ...cuve,
                cap_max: cuveCaps[camnum]?.[cuve.num_cuve] ?? cuve.vol ?? 0,
              }));
              ventilation[key] = enriched;
            }
          }
        }
      }
    }

    return NextResponse.json({
      routes: response.routes || [],
      unassigned: response.unassigned || [],
      ventilation,
      challenge,
      nb_iterations: mainRow[0].NB_ITERATIONS || null,
    });
  } catch (error: any) {
    console.error('Results API error:', error);
    return NextResponse.json({ error: error.message }, { status: 500 });
  }
}
