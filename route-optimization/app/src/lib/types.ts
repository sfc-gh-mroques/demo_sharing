export interface Depot {
  no_depot: number;
  nom: string;
  ville: string;
  lon: number;
  lat: number;
  zone: string;
}

export interface Commande {
  client: string;
  ville: string;
  produit: string;
  qte_litres: number;
  heure_livraison: string | null;
  depot_chargement: number;
  zone: string;
}

export interface VroomRoute {
  vehicle: number;
  description: string;
  duration: number;
  service: number;
  geometry: [number, number][];
  steps: VroomStep[];
  amount?: number[];
}

export interface VroomStep {
  type: string;
  arrival: number;
  duration: number;
  service: number;
  location?: [number, number];
  id?: number;
  description?: string;
}

export const PRODUCT_COLORS: Record<string, string> = {
  "GNR": "#27AE60",
  "Traction Force Plus": "#7D44CF",
  "Gazole": "#29B5E8",
  "Fioul Domestique": "#FF9F36",
  "HVO Non Routier": "#75CDD7",
  "HVO Routier": "#16A085",
  "SP95": "#D45B90",
  "Gazole Plus": "#11567F",
};

export const VEHICLE_COLORS = [
  "#29B5E8", "#7D44CF", "#27AE60", "#FF9F36", "#D45B90",
  "#75CDD7", "#11567F", "#F39C12", "#9B59B6", "#2ECC71",
  "#3498DB", "#C0392B", "#95A5A6", "#2C3E50", "#F1C40F",
];
