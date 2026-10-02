'use client';
import { VEHICLE_COLORS } from '@/lib/types';

interface Route {
  vehicle: number;
  description: string;
  duration: number;
  service: number;
  steps: any[];
  geometry?: [number, number][];
}

interface RouteMetric {
  vehicle_id: number;
  distance_km: number;
  duree_totale_sec: number;
  nb_livraisons: number;
}

interface RouteListProps {
  routes: Route[];
  routeMetrics?: RouteMetric[];
  selectedRoute: number | null;
  onSelect: (idx: number | null) => void;
}

function formatDuration(secs: number): string {
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  if (h > 0) return `${h}h${m.toString().padStart(2, '0')}`;
  return `${m}min`;
}

export default function RouteList({ routes, routeMetrics, selectedRoute, onSelect }: RouteListProps) {
  return (
    <div className="bg-[#111827] border border-[#1f2937] rounded-xl overflow-hidden">
      <div className="px-4 py-3 border-b border-[#1f2937]">
        <h3 className="text-sm font-semibold text-gray-200">Tournées ({routes.length})</h3>
      </div>
      <div className="max-h-[400px] overflow-y-auto">
        {routes.map((route, idx) => {
          const deliveries = route.steps.filter((s: any) => s.type === 'job');
          const isSelected = selectedRoute === idx;
          const metric = routeMetrics?.find(m => m.vehicle_id === route.vehicle);
          const durationSec = route.steps.length >= 2
            ? route.steps[route.steps.length - 1].arrival - route.steps[0].arrival
            : route.duration;
          return (
            <div
              key={idx}
              onClick={() => onSelect(isSelected ? null : idx)}
              className={`px-4 py-3 border-b border-[#1f2937] cursor-pointer transition-colors ${
                isSelected ? 'bg-[#1e293b]' : 'hover:bg-[#0f172a]'
              }`}
            >
              <div className="flex items-center gap-2">
                <div className="w-3 h-3 rounded-full" style={{ backgroundColor: VEHICLE_COLORS[idx % VEHICLE_COLORS.length] }} />
                <span className="font-medium text-sm">{route.description || `Véhicule ${route.vehicle}`}</span>
              </div>
              <div className="flex gap-4 mt-1 text-xs text-gray-400">
                <span>{deliveries.length} livraisons</span>
                <span>{formatDuration(metric?.duree_totale_sec ?? durationSec)}</span>
                {metric && <span>{metric.distance_km.toFixed(0)} km</span>}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
