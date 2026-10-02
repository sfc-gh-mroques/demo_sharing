'use client';
import { useState } from 'react';
import { PRODUCT_COLORS } from '@/lib/types';

interface Cuve {
  num_cuve: number;
  cap_max?: number;  // physical capacity of the cuve
  vol?: number;      // volume actually loaded
  cap?: number;      // legacy: used as vol if vol not present
  produit: string | null;
}

interface VentilationPanelProps {
  ventilation: Record<string, Cuve[]>;
}

export default function VentilationPanel({ ventilation }: VentilationPanelProps) {
  const vehicles = Object.keys(ventilation).sort();
  const [hoveredCuve, setHoveredCuve] = useState<string | null>(null);

  if (vehicles.length === 0) {
    return <p className="text-gray-500 text-sm">Pas de données de ventilation.</p>;
  }

  return (
    <div className="bg-[#111827] border border-[#1f2937] rounded-xl overflow-hidden">
      <div className="px-4 py-3 border-b border-[#1f2937]">
        <h3 className="text-sm font-semibold text-gray-200">Ventilation Cuves</h3>
      </div>
      <div className="max-h-[400px] overflow-y-auto p-4 space-y-4">
        {vehicles.map((veh) => {
          const cuves = ventilation[veh];
          if (!Array.isArray(cuves)) return null;
          return (
            <div key={veh}>
              <p className="text-xs font-semibold text-gray-300 mb-2">{veh}</p>
              <div className="flex gap-1 relative">
                {cuves.map((cuve, i) => {
                  const capMax = cuve.cap_max ?? cuve.cap ?? 0;
                  const vol = cuve.vol ?? cuve.cap ?? 0;
                  const fillRatio = capMax > 0 ? Math.min(vol / capMax, 1) : 0;
                  const color = cuve.produit ? PRODUCT_COLORS[cuve.produit] || '#4B5563' : '#1f2937';
                  const emptyColor = '#1f2937';
                  const width = Math.max((capMax / 12000) * 100, 12);
                  const cuveKey = `${veh}-${i}`;
                  return (
                    <div
                      key={i}
                      className="rounded h-12 relative cursor-default"
                      style={{ width: `${width}%`, minWidth: '60px' }}
                      onMouseEnter={() => setHoveredCuve(cuveKey)}
                      onMouseLeave={() => setHoveredCuve(null)}
                    >
                      {/* Cuve container with overflow-hidden for fill clipping */}
                      <div className="absolute inset-0 rounded overflow-hidden" style={{ border: '1px solid #374151', backgroundColor: emptyColor }}>
                        {/* Fill level */}
                        <div
                          className="absolute bottom-0 left-0 right-0 transition-all"
                          style={{ backgroundColor: color, height: `${fillRatio * 100}%` }}
                        />
                      </div>
                      {/* Label */}
                      <div className="absolute inset-0 flex flex-col items-center justify-center text-white z-10">
                        <span className="text-[9px] leading-tight text-center px-1 truncate w-full font-medium drop-shadow-sm">
                          {cuve.produit || 'Vide'}
                        </span>
                        {vol > 0 && (
                          <span className="text-[8px] text-gray-300 drop-shadow-sm">
                            {(vol / 1000).toFixed(1)}m³
                          </span>
                        )}
                      </div>
                      {/* Tooltip */}
                      {hoveredCuve === cuveKey && (
                        <div className="absolute -top-12 left-1/2 -translate-x-1/2 bg-black/95 border border-gray-600 rounded px-2 py-1 text-[10px] whitespace-nowrap z-50 shadow-lg text-white">
                          Cuve {cuve.num_cuve} — taille: {(capMax / 1000).toFixed(1)}m³
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
