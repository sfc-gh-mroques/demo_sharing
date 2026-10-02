'use client';
import { useState, useEffect, useRef } from 'react';
import KPIBanner from '@/components/KPIBanner';
import RouteList from '@/components/RouteList';
import RouteMap from '@/components/RouteMap';
import VentilationPanel from '@/components/VentilationPanel';
import CommandeTable from '@/components/CommandeTable';
import RoutePlanning from '@/components/RoutePlanning';
import ChatPanel from '@/components/ChatPanel';
import type { Depot, Commande } from '@/lib/types';

export default function Home() {
  const [result, setResult] = useState<any>(null);
  const [metrics, setMetrics] = useState<any>(null);
  const [depots, setDepots] = useState<Depot[]>([]);
  const [commandes, setCommandes] = useState<Commande[]>([]);
  const [selectedRoute, setSelectedRoute] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);
  const [chatOpen, setChatOpen] = useState(false);
  const fetched = useRef(false);

  useEffect(() => {
    if (fetched.current) return;
    fetched.current = true;
    Promise.all([
      fetch('/api/results').then(r => r.json()).catch(() => ({})),
      fetch('/api/commandes').then(r => r.json()).catch(() => []),
      fetch('/api/depots').then(r => r.json()).catch(() => []),
      fetch('/api/metrics').then(r => r.json()).catch(() => null),
    ]).then(([res, cmd, dep, met]) => {
      setResult(res?.error ? {} : res);
      setCommandes(Array.isArray(cmd) ? cmd : []);
      setDepots(Array.isArray(dep) ? dep : []);
      setMetrics(met?.kpi ? met : null);
      setLoading(false);
    });
  }, []);

  const routes = result?.routes || [];
  const unassigned = result?.unassigned || [];
  const ventilation = result?.ventilation || {};
  const nbIterations = result?.nb_iterations || null;
  const totalKm = metrics?.kpi?.distance_totale_km ?? 0;
  const uniqueVehicles = new Set(routes.map((r: any) => r.vehicle)).size;

  // Ventilation is now stored per-route (effective products only), no filtering needed
  const activeVentilation = ventilation;

  return (
    <main className="min-h-screen p-6 max-w-[1600px] mx-auto">
      {/* Header */}
      <div className="flex items-center justify-between mb-8">
        <div>
          <h1 className="text-2xl font-bold">
            <span className="text-sf-blue">Fleet Intelligence</span> — Optimisation de Tournées
          </h1>
          <p className="text-sm text-gray-400 mt-1">Distribution multi-produits pétroliers</p>
        </div>
        <div className="flex items-center gap-2">
          <div className="w-8 h-8 bg-sf-blue rounded-lg flex items-center justify-center">
            <svg className="w-5 h-5 text-white" fill="currentColor" viewBox="0 0 24 24">
              <path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5" />
            </svg>
          </div>
          <span className="text-xs text-gray-500">Powered by Snowflake</span>
        </div>
      </div>

      {loading ? (
        <div className="flex items-center justify-center h-64">
          <div className="animate-spin w-8 h-8 border-2 border-sf-blue border-t-transparent rounded-full" />
        </div>
      ) : (
        <>
          {/* KPI Banner */}
          <KPIBanner
            totalKm={totalKm}
            unassigned={unassigned.length}
            numVehicles={uniqueVehicles}
            numRoutes={routes.length}
            nbIterations={nbIterations}
            totalLivraisons={metrics?.kpi?.total_livraisons}
          />

          {/* Main content grid */}
          <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
            {/* Left: Route list */}
            <div className="lg:col-span-1 space-y-4">
              <RouteList
                routes={routes}
                routeMetrics={metrics?.routes}
                selectedRoute={selectedRoute}
                onSelect={setSelectedRoute}
              />
              <VentilationPanel ventilation={activeVentilation} />
            </div>

            {/* Right: Map + Planning */}
            <div className="lg:col-span-2 space-y-4">
              <RouteMap
                routes={routes}
                depots={depots}
                selectedRoute={selectedRoute}
              />
              {selectedRoute !== null && routes[selectedRoute] && (
                <RoutePlanning
                  route={routes[selectedRoute]}
                  routeIndex={selectedRoute}
                />
              )}
            </div>
          </div>

          {/* Commandes table */}
          <div className="mt-6">
            <CommandeTable commandes={commandes} />
          </div>

          {/* Unassigned section */}
          {unassigned.length > 0 && (
            <div className="mt-6 bg-[#111827] border border-red-900/30 rounded-xl p-4">
              <h3 className="text-sm font-semibold text-red-400 mb-2">
                Commandes non assignées ({unassigned.length})
              </h3>
              <div className="flex flex-wrap gap-2">
                {unassigned.map((u: any, i: number) => (
                  <span key={i} className="px-2 py-1 bg-red-900/20 border border-red-800/30 rounded text-xs text-red-300">
                    {u.description || `Job ${u.id}`}
                  </span>
                ))}
              </div>
            </div>
          )}
        </>
      )}

      {/* Chat floating button */}
      <button
        onClick={() => setChatOpen(true)}
        className="fixed bottom-6 right-6 w-14 h-14 bg-sf-blue hover:bg-blue-600 text-white rounded-full shadow-lg shadow-sf-blue/30 flex items-center justify-center transition-all z-[9999]"
        title="Poser une question"
      >
        <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M8 10h.01M12 10h.01M16 10h.01M9 16H5a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v8a2 2 0 01-2 2h-5l-5 5v-5z" />
        </svg>
      </button>

      {/* Chat panel */}
      <ChatPanel open={chatOpen} onClose={() => setChatOpen(false)} />
    </main>
  );
}
