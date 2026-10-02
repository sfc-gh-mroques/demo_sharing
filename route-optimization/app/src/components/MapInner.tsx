'use client';
import { useMemo, useEffect } from 'react';
import { MapContainer, TileLayer, Polyline, CircleMarker, Popup, useMap } from 'react-leaflet';
import { VEHICLE_COLORS } from '@/lib/types';
import type { Depot } from '@/lib/types';

interface Route {
  vehicle: number;
  description: string;
  geometry?: [number, number][];
  steps: any[];
}

interface MapInnerProps {
  routes: Route[];
  depots: Depot[];
  selectedRoute: number | null;
}

function FitBounds({ routes, selectedRoute }: { routes: Route[]; selectedRoute: number | null }) {
  const map = useMap();
  useEffect(() => {
    const visible = selectedRoute !== null && routes[selectedRoute]
      ? [routes[selectedRoute]]
      : routes;
    const points: [number, number][] = [];
    for (const route of visible) {
      if (route.geometry) {
        for (const [lon, lat] of route.geometry) {
          points.push([lat, lon]);
        }
      }
    }
    if (points.length > 1) {
      map.fitBounds(points, { padding: [30, 30] });
    }
  }, [routes, selectedRoute, map]);
  return null;
}

export default function MapInner({ routes, depots, selectedRoute }: MapInnerProps) {
  const center: [number, number] = [48.85, 2.6];

  const visibleRoutes = useMemo(() => {
    if (selectedRoute !== null && routes[selectedRoute]) return [{ route: routes[selectedRoute], idx: selectedRoute }];
    if (selectedRoute !== null) return [];
    return routes.map((route, idx) => ({ route, idx }));
  }, [routes, selectedRoute]);

  return (
    <MapContainer center={center} zoom={9} className="h-full w-full bg-[#0a0e1a]">
      <TileLayer
        url="https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png"
        attribution='&copy; <a href="https://carto.com">CARTO</a>'
      />
      <FitBounds routes={routes} selectedRoute={selectedRoute} />
      {depots.map((d) => (
        <CircleMarker
          key={d.no_depot}
          center={[d.lat, d.lon]}
          radius={4}
          pathOptions={{ color: '#FF9F36', fillColor: '#FF9F36', fillOpacity: 0.9, weight: 1.5 }}
        >
          <Popup>
            <span className="text-xs font-semibold">{d.nom} ({d.ville})</span>
          </Popup>
        </CircleMarker>
      ))}
      {visibleRoutes.map(({ route, idx }) => {
        const color = VEHICLE_COLORS[idx % VEHICLE_COLORS.length];
        if (!route.geometry || route.geometry.length === 0) return null;
        const positions = route.geometry.map(([lon, lat]: [number, number]) => [lat, lon] as [number, number]);
        return (
          <Polyline
            key={`line-${idx}`}
            positions={positions}
            pathOptions={{ color, weight: 3, opacity: 0.8 }}
          />
        );
      })}
      {visibleRoutes.map(({ route, idx }) => {
        const color = VEHICLE_COLORS[idx % VEHICLE_COLORS.length];
        return route.steps
          .filter((s: any) => s.type === 'job' && s.location)
          .map((step: any, si: number) => (
            <CircleMarker
              key={`pt-${idx}-${si}`}
              center={[step.location[1], step.location[0]]}
              radius={5}
              pathOptions={{ color, fillColor: color, fillOpacity: 0.8, weight: 1 }}
            >
              <Popup>
                <span className="text-xs">{step.description || `Livraison ${step.id}`}</span>
              </Popup>
            </CircleMarker>
          ));
      })}
    </MapContainer>
  );
}
