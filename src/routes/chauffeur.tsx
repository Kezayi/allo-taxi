import { createFileRoute, Link } from "@tanstack/react-router";
import {
  ArrowLeft,
  BadgeCheck,
  Banknote,
  CarFront,
  CheckCircle2,
  Clock3,
  MapPin,
  Navigation,
  Phone,
  RefreshCw,
  ShieldCheck,
  Snowflake,
  Sparkles,
  UserRound,
  Wifi,
  WifiOff,
  Wind,
  XCircle,
} from "lucide-react";
import { useEffect, useMemo, useState } from "react";

import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/switch";
import { cn } from "@/lib/utils";

export const Route = createFileRoute("/chauffeur")({
  head: () => ({
    meta: [
      { title: "Poste de conduite — Allo Taxi..?" },
      { name: "description", content: "Le poste de travail mobile des chauffeurs Allo Taxi..? à Libreville." },
      { property: "og:title", content: "Poste de conduite — Allo Taxi..?" },
      { property: "og:description", content: "Activez votre disponibilité et consultez les courses à proximité." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: DriverWorkspace,
});

type Payment = "Espèces" | "AirtelMoney" | "MoovMoney";

type RideOffer = {
  id: string;
  client: string;
  phone: string;
  distance: number;
  pickup: string;
  destination: string;
  payment: Payment;
  airConditioning: boolean;
  price: number;
};

type PersistedDriverState = {
  accessActive: boolean;
  isOnline: boolean;
  airConditioning: boolean;
  selectedRideId: string | null;
};

const STORAGE_KEY = "allo-taxi-driver-workspace-v1";

const rideOffers: RideOffer[] = [
  { id: "course-1", client: "Amina", phone: "24106123456", distance: 1.2, pickup: "Charbonnages, Entrée SNI", destination: "Nzeng-Ayong, Rond-point", payment: "AirtelMoney", airConditioning: true, price: 2000 },
  { id: "course-2", client: "Junior", phone: "24107458732", distance: 0.8, pickup: "Louis, face à l’église Saint-Louis", destination: "Glass, échangeur du Lycée Léon Mba", payment: "Espèces", airConditioning: false, price: 1500 },
  { id: "course-3", client: "Mireille", phone: "24106552148", distance: 3.7, pickup: "Akébé-Plaine, pharmacie des Nations", destination: "Aéroport de Libreville, départs", payment: "MoovMoney", airConditioning: true, price: 3500 },
  { id: "course-4", client: "Cédric", phone: "24107773619", distance: 4.6, pickup: "PK8, carrefour Bizango", destination: "Centre-ville, boulevard Triomphal", payment: "Espèces", airConditioning: false, price: 2500 },
];

const defaultState: PersistedDriverState = {
  accessActive: true,
  isOnline: false,
  airConditioning: true,
  selectedRideId: null,
};

function DriverWorkspace() {
  const [state, setState] = useState<PersistedDriverState>(defaultState);
  const [hydrated, setHydrated] = useState(false);
  const [networkOnline, setNetworkOnline] = useState(true);
  const [notice, setNotice] = useState<string | null>(null);

  useEffect(() => {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored) {
      try {
        const parsed = JSON.parse(stored) as Partial<PersistedDriverState>;
        setState({
          accessActive: parsed.accessActive ?? true,
          isOnline: parsed.isOnline ?? false,
          airConditioning: parsed.airConditioning ?? true,
          selectedRideId: parsed.selectedRideId ?? null,
        });
      } catch {
        localStorage.removeItem(STORAGE_KEY);
      }
    }
    setNetworkOnline(navigator.onLine);
    setHydrated(true);
  }, []);

  useEffect(() => {
    const updateNetwork = () => setNetworkOnline(navigator.onLine);
    window.addEventListener("online", updateNetwork);
    window.addEventListener("offline", updateNetwork);
    return () => {
      window.removeEventListener("online", updateNetwork);
      window.removeEventListener("offline", updateNetwork);
    };
  }, []);

  useEffect(() => {
    if (hydrated) localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  }, [hydrated, state]);

  useEffect(() => {
    if (!notice) return;
    const timeout = window.setTimeout(() => setNotice(null), 4000);
    return () => window.clearTimeout(timeout);
  }, [notice]);

  const selectedRide = rideOffers.find((ride) => ride.id === state.selectedRideId) ?? null;
  const visibleOffers = useMemo(
    () => rideOffers.filter((ride) => state.airConditioning || !ride.airConditioning),
    [state.airConditioning],
  );

  function patchState(update: Partial<PersistedDriverState>) {
    setState((current) => ({ ...current, ...update }));
  }

  function finishRide(success: boolean) {
    patchState({ selectedRideId: null });
    setNotice(success ? "Course validée. Mise en relation enregistrée." : "Discussion annulée. Le client peut republier sa demande.");
  }

  return (
    <main className="relative min-h-svh overflow-hidden bg-background px-4 py-5 text-foreground sm:px-6 sm:py-8">
      <div className="taxi-grid pointer-events-none absolute inset-0" />
      <div className="relative mx-auto w-full max-w-4xl">
        <header className="grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-3">
          <Button asChild variant="ghost" size="icon" className="border border-border bg-secondary">
            <Link to="/" aria-label="Retour à l’accueil"><ArrowLeft /></Link>
          </Button>
          <div className="min-w-0 text-center">
            <p className="truncate text-sm font-semibold">Allo Taxi<span className="text-primary">..?</span></p>
            <p className="text-[10px] uppercase text-muted-foreground">Poste de conduite</p>
          </div>
          <span className={cn("flex items-center gap-1.5 text-[10px] font-semibold uppercase", networkOnline ? "text-live" : "text-primary")}>
            {networkOnline ? <Wifi className="size-3.5" /> : <WifiOff className="size-3.5" />}
            {networkOnline ? "Connecté" : "Hors réseau"}
          </span>
        </header>

        {!networkOnline && (
          <div className="mt-5 flex items-center gap-3 rounded-md border border-primary/30 bg-primary/10 px-4 py-3 text-xs text-primary" role="status">
            <RefreshCw className="size-4 shrink-0" />Vos réglages restent disponibles et seront conservés sur cet appareil.
          </div>
        )}

        {notice && (
          <div className="mt-5 flex items-center gap-3 rounded-md border border-live/30 bg-live/10 px-4 py-3 text-sm text-live" role="status">
            <CheckCircle2 className="size-4 shrink-0" />{notice}
          </div>
        )}

        <section className="relative mt-6">
          <div className="flex min-h-12 items-center justify-between gap-3 rounded-md border border-primary/35 bg-primary px-4 py-3 text-primary-foreground shadow-gold">
            <p className="flex min-w-0 items-center gap-2 text-xs font-black uppercase sm:text-sm"><Sparkles className="size-4 shrink-0" />Accès actif — Expire à 23h59</p>
            <Button type="button" variant="ghost" onClick={() => patchState({ accessActive: false, isOnline: false })} className="h-7 shrink-0 px-2 text-[10px] text-primary-foreground hover:bg-background/10 hover:text-primary-foreground">Tester inactif</Button>
          </div>

          <div className={cn("mt-5 space-y-5 transition duration-700", !state.accessActive && "pointer-events-none select-none blur-md")} aria-hidden={!state.accessActive}>
            <ActivationDashboard state={state} onPatch={patchState} />

            {selectedRide ? (
              <NegotiationScreen ride={selectedRide} onFinish={finishRide} />
            ) : state.isOnline ? (
              <RidePool offers={visibleOffers} airConditioning={state.airConditioning} onTake={(id) => patchState({ selectedRideId: id })} />
            ) : (
              <OfflinePanel />
            )}
          </div>

          {!state.accessActive && (
            <div className="absolute inset-0 z-20 grid min-h-[560px] place-items-center bg-background/55 px-5 backdrop-blur-md">
              <div className="max-w-sm text-center">
                <div className="mx-auto grid size-14 place-items-center rounded-md border border-primary/30 bg-primary/10 text-primary"><ShieldCheck className="size-7" /></div>
                <p className="mt-5 text-xs font-semibold uppercase text-primary">Journée non activée</p>
                <h1 className="mt-2 text-2xl font-semibold">Activez votre accès pour recevoir des courses.</h1>
                <p className="mt-3 text-sm leading-6 text-muted-foreground">Activation valable jusqu’à 23h59, même en cas de coupure momentanée.</p>
                <Button type="button" onClick={() => patchState({ accessActive: true })} className="mt-6 h-14 w-full text-sm font-bold shadow-gold"><Banknote />Activer ma journée — 1 000 FCFA via Xfin</Button>
              </div>
            </div>
          )}
        </section>
      </div>
    </main>
  );
}

function ActivationDashboard({ state, onPatch }: { state: PersistedDriverState; onPatch: (update: Partial<PersistedDriverState>) => void }) {
  return (
    <section className="glass-panel p-5 sm:p-7">
      <div className="grid gap-5 sm:grid-cols-2">
        <label className={cn("flex min-h-28 cursor-pointer items-center justify-between gap-4 rounded-md border p-5 transition-colors", state.isOnline ? "border-live/45 bg-live/10" : "border-border bg-secondary/60")}>
          <span>
            <span className={cn("block text-xs font-black uppercase", state.isOnline ? "text-live" : "text-muted-foreground")}>{state.isOnline ? "● En ligne" : "● Hors ligne"}</span>
            <span className="mt-2 block text-sm text-muted-foreground">{state.isOnline ? "Vous recevez les demandes proches." : "Aucune demande ne vous sera proposée."}</span>
          </span>
          <Switch checked={state.isOnline} onCheckedChange={(checked) => onPatch({ isOnline: checked })} aria-label="Disponibilité en ligne" className="h-8 w-14 data-[state=checked]:bg-live [&>span]:size-7 [&>span]:data-[state=checked]:translate-x-6" />
        </label>

        <label className={cn("flex min-h-28 cursor-pointer items-center justify-between gap-4 rounded-md border p-5 transition-colors", state.airConditioning ? "border-primary/45 bg-primary/10" : "border-border bg-secondary/60")}>
          <span className="flex min-w-0 items-start gap-3">
            <span className={cn("grid size-10 shrink-0 place-items-center rounded-md", state.airConditioning ? "bg-primary text-primary-foreground" : "bg-muted text-muted-foreground")}><Snowflake className="size-5" /></span>
            <span><span className="block text-sm font-semibold">Option Climatisation</span><span className="mt-1 block text-xs text-muted-foreground">{state.airConditioning ? "Active sur le véhicule" : "Indisponible sur le véhicule"}</span></span>
          </span>
          <Switch checked={state.airConditioning} onCheckedChange={(checked) => onPatch({ airConditioning: checked })} aria-label="Option climatisation du véhicule" />
        </label>
      </div>
    </section>
  );
}

function RidePool({ offers, airConditioning, onTake }: { offers: RideOffer[]; airConditioning: boolean; onTake: (id: string) => void }) {
  return (
    <section className="animate-journey-in">
      <div className="mb-4 flex items-end justify-between gap-4">
        <div><p className="text-xs font-semibold uppercase text-live">Flux en direct</p><h1 className="mt-1 text-2xl font-semibold">Courses à proximité</h1></div>
        <span className="shrink-0 rounded-md border border-border bg-secondary px-3 py-1.5 text-[10px] text-muted-foreground">{offers.length} disponibles</span>
      </div>
      {!airConditioning && <p className="mb-4 flex items-center gap-2 text-xs text-muted-foreground"><Wind className="size-4 text-primary" />Les demandes exigeant la climatisation sont masquées.</p>}
      <div className="space-y-4">
        {offers.map((ride) => <RideCard key={ride.id} ride={ride} onTake={() => onTake(ride.id)} />)}
      </div>
    </section>
  );
}

function RideCard({ ride, onTake }: { ride: RideOffer; onTake: () => void }) {
  return (
    <article className="glass-panel p-5 sm:p-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <span className="inline-flex items-center gap-1.5 rounded-md border border-primary/30 bg-primary/10 px-2.5 py-1.5 text-[11px] font-semibold text-primary"><MapPin className="size-3.5" />À {ride.distance.toFixed(1)} km de vous</span>
        <div className="text-right"><p className="text-[10px] uppercase text-muted-foreground">Prix proposé</p><p className="mt-1 text-2xl font-black text-primary">{ride.price.toLocaleString("fr-FR")} <span className="text-sm">FCFA</span></p></div>
      </div>
      <RouteDetails ride={ride} />
      <div className="mt-5 flex flex-wrap items-center justify-between gap-3 border-t border-border pt-4">
        <div className="flex flex-wrap gap-2">
          <RequirementBadge icon={<Banknote />} label={ride.payment} />
          <RequirementBadge icon={ride.airConditioning ? <Snowflake /> : <Wind />} label={ride.airConditioning ? "Climatisation exigée" : "Standard"} highlight={ride.airConditioning} />
        </div>
        <Button type="button" onClick={onTake} className="h-11 w-full px-7 font-bold shadow-gold sm:w-auto">Prendre <Navigation /></Button>
      </div>
    </article>
  );
}

function NegotiationScreen({ ride, onFinish }: { ride: RideOffer; onFinish: (success: boolean) => void }) {
  const message = encodeURIComponent(`Bonjour ${ride.client}, je suis votre chauffeur Allo Taxi..? Je souhaite confirmer votre trajet de ${ride.pickup} vers ${ride.destination}, au tarif proposé de ${ride.price.toLocaleString("fr-FR")} FCFA, règlement ${ride.payment}${ride.airConditioning ? ", avec climatisation" : ""}. Où puis-je vous retrouver précisément ?`);
  return (
    <section className="glass-panel animate-journey-in overflow-hidden">
      <div className="border-b border-live/25 bg-live/10 px-5 py-4 text-center text-xs font-bold uppercase text-live"><span className="mr-2 inline-block size-2 rounded-full bg-live" />Course verrouillée — Discussion en cours</div>
      <div className="p-5 sm:p-8">
        <div className="text-center">
          <div className="mx-auto grid size-14 place-items-center rounded-md bg-primary/10 text-primary"><UserRound className="size-7" /></div>
          <p className="mt-4 text-xs font-semibold uppercase text-primary">Client à contacter</p>
          <h1 className="mt-2 text-3xl font-semibold">{ride.client}</h1>
          <p className="mt-2 text-sm text-muted-foreground">À {ride.distance.toFixed(1)} km · Offre à {ride.price.toLocaleString("fr-FR")} FCFA</p>
        </div>

        <RouteDetails ride={ride} prominent />

        <div className="mt-5 flex flex-wrap justify-center gap-2">
          <RequirementBadge icon={<Banknote />} label={ride.payment} />
          <RequirementBadge icon={ride.airConditioning ? <Snowflake /> : <Wind />} label={ride.airConditioning ? "Climatisation exigée" : "Standard"} highlight={ride.airConditioning} />
        </div>

        <Button asChild className="mt-6 h-14 w-full bg-live text-sm font-bold text-foreground shadow-live hover:bg-live/90">
          <a href={`https://wa.me/${ride.phone}?text=${message}`} target="_blank" rel="noreferrer"><Phone />Ouvrir WhatsApp pour négocier</a>
        </Button>

        <div className="mt-7 border-t border-border pt-5">
          <p className="mb-4 text-center text-xs leading-5 text-muted-foreground">Clôturez obligatoirement la discussion pour recevoir une nouvelle course.</p>
          <div className="grid gap-3 sm:grid-cols-2">
            <Button type="button" variant="outline" onClick={() => onFinish(false)} className="min-h-12 whitespace-normal border-destructive/40 text-xs text-destructive hover:bg-destructive/10 hover:text-destructive"><XCircle />Annuler — Échec de la discussion</Button>
            <Button type="button" onClick={() => onFinish(true)} className="min-h-12 whitespace-normal bg-live text-xs font-bold text-foreground hover:bg-live/90"><CheckCircle2 />Embarqué — Course validée</Button>
          </div>
        </div>
      </div>
    </section>
  );
}

function OfflinePanel() {
  return (
    <section className="glass-panel grid min-h-72 place-items-center p-8 text-center">
      <div><div className="mx-auto grid size-14 place-items-center rounded-md bg-secondary text-muted-foreground"><CarFront className="size-7" /></div><h1 className="mt-5 text-2xl font-semibold">Vous êtes hors ligne.</h1><p className="mx-auto mt-2 max-w-sm text-sm leading-6 text-muted-foreground">Activez votre disponibilité pour voir les demandes proches qui correspondent à votre véhicule.</p></div>
    </section>
  );
}

function RouteDetails({ ride, prominent = false }: { ride: RideOffer; prominent?: boolean }) {
  return (
    <div className={cn("mt-5 grid grid-cols-[24px_minmax(0,1fr)] gap-x-3 gap-y-4", prominent && "rounded-md border border-border bg-background/35 p-4")}>
      <span className="grid size-6 place-items-center rounded-full bg-live/15 text-live"><MapPin className="size-3.5" /></span><p className="min-w-0 break-words text-sm"><span className="mb-1 block text-[10px] font-semibold uppercase text-muted-foreground">Départ</span>{ride.pickup}</p>
      <span className="grid size-6 place-items-center rounded-full bg-primary/15 text-primary"><Navigation className="size-3.5" /></span><p className="min-w-0 break-words text-sm"><span className="mb-1 block text-[10px] font-semibold uppercase text-muted-foreground">Destination</span>{ride.destination}</p>
    </div>
  );
}

function RequirementBadge({ icon, label, highlight = false }: { icon: React.ReactNode; label: string; highlight?: boolean }) {
  return <span className={cn("inline-flex items-center gap-1.5 rounded-md border px-2.5 py-1.5 text-[10px] font-semibold [&_svg]:size-3.5", highlight ? "border-primary/30 bg-primary/10 text-primary" : "border-border bg-secondary text-muted-foreground")}>{icon}{label}</span>;
}