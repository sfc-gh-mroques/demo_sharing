'use client';
import { Commande } from '@/lib/types';
import { PRODUCT_COLORS } from '@/lib/types';

interface CommandeTableProps {
  commandes: Commande[];
}

export default function CommandeTable({ commandes }: CommandeTableProps) {
  return (
    <div className="bg-[#111827] border border-[#1f2937] rounded-xl overflow-hidden">
      <div className="px-4 py-3 border-b border-[#1f2937]">
        <h3 className="text-sm font-semibold text-gray-200">Livraisons à effectuer ({commandes.length})</h3>
      </div>
      <div className="overflow-x-auto max-h-[350px] overflow-y-auto">
        <table className="w-full text-xs">
          <thead className="bg-[#0f172a] sticky top-0">
            <tr>
              <th className="px-3 py-2 text-left text-gray-400">Client</th>
              <th className="px-3 py-2 text-left text-gray-400">Ville</th>
              <th className="px-3 py-2 text-left text-gray-400">Produit</th>
              <th className="px-3 py-2 text-right text-gray-400">Quantité (L)</th>
              <th className="px-3 py-2 text-left text-gray-400">Zone</th>
            </tr>
          </thead>
          <tbody>
            {commandes.map((c, i) => (
              <tr key={i} className="border-t border-[#1f2937] hover:bg-[#0f172a]">
                <td className="px-3 py-2 text-gray-200">{c.client}</td>
                <td className="px-3 py-2 text-gray-300">{c.ville}</td>
                <td className="px-3 py-2">
                  <span className="inline-flex items-center gap-1">
                    <span className="w-2 h-2 rounded-full" style={{ backgroundColor: PRODUCT_COLORS[c.produit] || '#6B7280' }} />
                    <span className="text-gray-200">{c.produit}</span>
                  </span>
                </td>
                <td className="px-3 py-2 text-right text-gray-200 font-mono">{c.qte_litres.toLocaleString()}</td>
                <td className="px-3 py-2 text-gray-300">{c.zone}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
