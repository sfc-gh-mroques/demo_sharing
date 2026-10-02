'use client';

interface KPIBannerProps {
  totalKm: number;
  unassigned: number;
  numVehicles: number;
  numRoutes: number;
  nbIterations: number | null;
  totalLivraisons?: number;
}

export default function KPIBanner({ totalKm, unassigned, numVehicles, numRoutes, nbIterations, totalLivraisons }: KPIBannerProps) {
  const cards = [
    { label: 'Distance totale', value: `${totalKm.toFixed(0)} km` },
    { label: 'Livraisons', value: `${totalLivraisons ?? '—'}`, sub: `${unassigned} non assignées` },
    { label: 'Véhicules', value: `${numVehicles}`, sub: `${numRoutes} tournées` },
    { label: 'Non assignées', value: `${unassigned}`, positive: unassigned === 0 },
    ...(nbIterations ? [{ label: 'Combinaisons testées', value: `${nbIterations}`, sub: 'algorithme génétique' }] : []),
  ];

  return (
    <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-5 gap-4 mb-6">
      {cards.map((c, i) => (
        <div key={i} className="bg-[#111827] border border-[#1f2937] rounded-xl p-4">
          <p className="text-xs text-gray-400 uppercase tracking-wider">{c.label}</p>
          <p className="text-2xl font-bold mt-1">{c.value}</p>
          {c.sub && <p className="text-xs mt-1 text-gray-500">{c.sub}</p>}
        </div>
      ))}
    </div>
  );
}
