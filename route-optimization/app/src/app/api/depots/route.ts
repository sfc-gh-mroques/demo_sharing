import { NextResponse } from 'next/server';
import { query } from '@/lib/snowflake';

export const dynamic = 'force-dynamic';

export async function GET() {
  try {
    const rows = await query(`
      SELECT NO_DEPOT, NOM, VILLE, LON, LAT, ZONE
      FROM DEPOT
      ORDER BY NO_DEPOT
    `);
    return NextResponse.json(rows.map((r: any) => ({
      no_depot: r.NO_DEPOT,
      nom: r.NOM,
      ville: r.VILLE,
      lon: r.LON,
      lat: r.LAT,
      zone: r.ZONE,
    })));
  } catch (error: any) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }
}
