'use client';
import type { Depot } from '@/lib/types';
import dynamic from 'next/dynamic';

const MapInner = dynamic(() => import('@/components/MapInner'), { ssr: false });

interface Route {
  vehicle: number;
  description: string;
  geometry?: [number, number][];
  steps: any[];
}

interface RouteMapProps {
  routes: Route[];
  depots: Depot[];
  selectedRoute: number | null;
}

export default function RouteMap({ routes, depots, selectedRoute }: RouteMapProps) {
  return (
    <div className="bg-[#111827] border border-[#1f2937] rounded-xl overflow-hidden h-[500px]">
      <MapInner routes={routes} depots={depots} selectedRoute={selectedRoute} />
    </div>
  );
}
