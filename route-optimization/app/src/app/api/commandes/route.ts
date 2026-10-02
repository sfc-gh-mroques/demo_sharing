import { NextResponse } from 'next/server';
import { query } from '@/lib/snowflake';

export const dynamic = 'force-dynamic';

export async function GET() {
  try {
    const rows = await query(`
      SELECT CLIENT, VILLE, PRODUIT, QTE_LITRES, HEURE_LIVRAISON, DEPOT_CHARGEMENT, ZONE
      FROM COMMANDES
      ORDER BY DEPOT_CHARGEMENT, CLIENT
    `);
    return NextResponse.json(rows.map((r: any) => ({
      client: r.CLIENT,
      ville: r.VILLE,
      produit: r.PRODUIT,
      qte_litres: r.QTE_LITRES,
      heure_livraison: r.HEURE_LIVRAISON,
      depot_chargement: r.DEPOT_CHARGEMENT,
      zone: r.ZONE,
    })));
  } catch (error: any) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }
}
