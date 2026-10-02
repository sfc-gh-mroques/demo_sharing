import './globals.css';
import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'Route Optimization — Fleet Intelligence',
  description: 'Optimisation de tournées de livraison multi-produits',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="fr">
      <head></head>
      <body className="min-h-screen">{children}</body>
    </html>
  );
}
