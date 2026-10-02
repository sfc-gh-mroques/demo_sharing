import { NextResponse } from 'next/server';
import { query } from '@/lib/snowflake';

export const dynamic = 'force-dynamic';

export async function GET() {
  try {
    const rows = await query('SELECT CURRENT_TIMESTAMP() AS ts, CURRENT_USER() AS usr, CURRENT_DATABASE() AS db');
    return NextResponse.json({ status: 'ok', ...rows[0] });
  } catch (error: any) {
    return NextResponse.json({ status: 'error', error: error.message }, { status: 500 });
  }
}
