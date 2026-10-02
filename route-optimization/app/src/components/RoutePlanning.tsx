'use client';
import { VEHICLE_COLORS } from '@/lib/types';

interface RoutePlanningProps {
  route: {
    vehicle: number;
    description: string;
    duration: number;
    steps: any[];
  };
  routeIndex: number;
}

function formatTime(seconds: number): string {
  // arrival is already seconds from midnight (e.g. 23130 = 6h25)
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return `${h.toString().padStart(2, '0')}:${m.toString().padStart(2, '0')}`;
}

function formatDuration(secs: number): string {
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  if (h > 0) return `${h}h${m.toString().padStart(2, '0')}`;
  return `${m}min`;
}

function stepLabel(type: string): string {
  switch (type) {
    case 'start': return 'Départ dépôt';
    case 'end': return 'Retour dépôt';
    case 'job': return 'Livraison';
    default: return type;
  }
}

export default function RoutePlanning({ route, routeIndex }: RoutePlanningProps) {
  const color = VEHICLE_COLORS[routeIndex % VEHICLE_COLORS.length];

  return (
    <div className="bg-[#111827] border border-[#1f2937] rounded-xl overflow-hidden mt-4">
      <div className="px-4 py-3 border-b border-[#1f2937] flex items-center gap-2">
        <div className="w-3 h-3 rounded-full" style={{ backgroundColor: color }} />
        <h3 className="text-sm font-semibold text-gray-200">
          Planning — {route.description || `Véhicule ${route.vehicle}`}
        </h3>
        <span className="text-xs text-gray-500 ml-auto">
          Durée totale : {formatDuration(
            route.steps.length >= 2
              ? route.steps[route.steps.length - 1].arrival - route.steps[0].arrival
              : route.duration
          )}
        </span>
      </div>
      <div className="p-4">
        <div className="relative">
          <div className="absolute left-[18px] top-3 bottom-3 w-[2px]" style={{ backgroundColor: color, opacity: 0.3 }} />
          <div className="space-y-0">
            {route.steps.map((step: any, i: number) => {
              const arrival = step.arrival != null ? formatTime(step.arrival) : '--:--';
              const serviceMin = step.service ? Math.round(step.service / 60) : 0;
              return (
                <div key={i} className="flex items-start gap-3 py-2 relative">
                  <div className="w-[38px] flex-shrink-0 flex justify-center">
                    <div
                      className="w-3 h-3 rounded-full border-2 z-10"
                      style={{
                        borderColor: color,
                        backgroundColor: step.type === 'job' ? color : '#111827',
                      }}
                    />
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-baseline gap-2">
                      <span className="text-xs font-mono text-gray-400">{arrival}</span>
                      <span className="text-xs font-medium text-gray-200">
                        {step.type === 'job' ? (step.description || `Livraison #${step.id}`) : stepLabel(step.type)}
                      </span>
                    </div>
                    {step.type === 'job' && serviceMin > 0 && (
                      <p className="text-[10px] text-gray-500 mt-0.5">
                        Service : {serviceMin} min
                      </p>
                    )}
                  </div>
                  {i < route.steps.length - 1 && (
                    <div className="text-[10px] text-gray-600 flex-shrink-0">
                      {route.steps[i + 1].arrival != null && step.arrival != null
                        ? formatDuration(route.steps[i + 1].arrival - step.arrival - (step.service || 0))
                        : ''}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </div>
      </div>
    </div>
  );
}
