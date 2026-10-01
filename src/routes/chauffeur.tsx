import { createFileRoute, Link } from "@tanstack/react-router";
import {
  ArrowLeft,
  BadgeCheck,
  Banknote,
  CarFront,
  CheckCircle2,
  Flag,
  Clock3,
  MapPin,
  Navigation,
  Phone,
  RefreshCw,
  Route as RouteIcon,
  ShieldCheck,
  Snowflake,
  Sparkles,
  UserRound,
  Users,
  Wifi,
  WifiOff,
  Wind,
  XCircle,
} from "lucide-react";
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { chimes } from "@/lib/chime";
import { z } from "zod";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import { useSession } from "@/hooks/use-session";
import { supabase } from "@/integrations/supabase/client";
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

type Payment = string;

type RideOffer = {
  id: string;
  client: string;
  phone: string;
  distance: number | null;
  pickup: string;
  destination: string;
  payment: Payment;
  airConditioning: boolean;
  price: number;
};

type ActiveRide = RideOffer & { status: "negotiating" | "onboard"; sharing: boolean; anchor: boolean };

type PersistedDriverState = {
  accessActive: boolean;
  isOnline: boolean;
  airConditioning: boolean;
  activeRides: ActiveRide[];
};

type DriverRow = { status: string; first_name: string; has_ac: boolean };

const STORAGE_KEY = "allo-taxi-driver-workspace-v3";
const MAX_SEATS = 3;
const POOL_REFRESH_MS = 10000;

const defaultState: PersistedDriverState = { accessActive: false, isOnline: false, airConditioning: true, activeRides: [] };

const registrationSchema = z.object({
  first_name: z.string().trim().min(2, "Prénom trop court.").max(40),
  phone: z.string().trim().regex(/^\+241[0-9]{8,9}$/, "Format attendu : +241 suivi de 8 ou 9 chiffres."),
  vehicle_model: z.string().trim().min(2, "Modèle requis.").max(60),
  vehicle_plate: z.string().trim().min(4, "Plaque requise.").max(15),
});

function getPosition(): Promise<{ lat: number; lng: number } | null> {
  return new Promise((resolve) => {
    if (!("geolocation" in navigator)) return resolve(null);
    navigator.geolocation.getCurrentPosition(
      (pos) => resolve({ lat: pos.coords.latitude, lng: pos.coords.longitude }),
      () => resolve(null),
      { enableHighAccuracy: true, timeout: 8000, maximumAge: 30000 },
    );
  });
}

function friendlyError(message: string | undefined) {
  if (!message) return "Action impossible pour le moment.";
  if (message.includes("déjà prise")) return "Cette course vient d’être prise par un autre chauffeur.";
  if (message.includes("Abonnement")) return "Activez votre journée pour recevoir des courses.";
  if (message.includes("TRAJET_VERROUILLE")) return message.split("TRAJET_VERROUILLE: ")[1] ? `Trajet verrouillé : ${message.split("TRAJET_VERROUILLE: ")[1]}.` : "Trajet verrouillé.";
  if (message.includes("Clôturez")) return "Clôturez d’abord votre course en cours.";
  return navigator.onLine ? "Action impossible pour le moment." : "Pas de réseau. Réessayez dès le retour de la connexion.";
}

function DriverWorkspace() {
  const { user, roles, loading } = useSession();
  const [driver, setDriver] = useState<DriverRow | null | undefined>(undefined);
  const [state, setState] = useState<PersistedDriverState>(defaultState);
  const [hydrated, setHydrated] = useState(false);
  const [networkOnline, setNetworkOnline] = useState(true);
  const [notice, setNotice] = useState<string | null>(null);
  const [offers, setOffers] = useState<RideOffer[]>([]);
  const [busy, setBusy] = useState(false);

  const isApproved = driver?.status === "approved" && roles.includes("chauffeur");

  useEffect(() => {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored) {
      try {
        setState({ ...defaultState, ...(JSON.parse(stored) as Partial<PersistedDriverState>) });
      } catch {
        localStorage.removeItem(STORAGE_KEY);
      }
    }
    setNetworkOnline(navigator.onLine);
    setHydrated(true);
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

  const seenRideIds = useRef(new Set<string>());
  const poolPrimed = useRef(false);
  const patchState = useCallback((update: Partial<PersistedDriverState>) => setState((current) => ({ ...current, ...update })), []);

  // Fiche chauffeur, abonnement du jour et course verrouillée côté serveur
  const loadDriver = useCallback(async () => {
    if (!user) return;
    const { data } = await supabase.from("drivers").select("status, first_name, has_ac").eq("user_id", user.id).maybeSingle();
    setDriver(data ?? null);
    if (!data || data.status !== "approved") return;
    const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Africa/Libreville" }).format(new Date());
    const [{ data: sub }, { data: current }] = await Promise.all([
      supabase.from("subscriptions").select("id").eq("driver_id", user.id).eq("day", today).eq("status", "active").maybeSingle(),
      supabase.from("rides").select("*").eq("chauffeur_id", user.id).in("status", ["negotiating", "onboard"]).order("started_negotiation_at"),
    ]);
    patchState({
      accessActive: Boolean(sub),
      airConditioning: data.has_ac,
      ...(sub ? {} : { isOnline: false }),
      activeRides: (current ?? []).map((row) => ({ id: row.id, client: row.client_name, phone: row.client_phone, distance: null, pickup: row.pickup_location, destination: row.dropoff_location, payment: row.payment_method, airConditioning: row.wants_ac, price: row.price_proposed, status: row.status === "onboard" ? "onboard" as const : "negotiating" as const, sharing: row.allow_sharing, anchor: row.anchor_ride_id === null })),
    });
  }, [patchState, user]);

  useEffect(() => { void loadDriver(); }, [loadDriver]);

  // Pool localisé : rafraîchi toutes les 10 s quand le chauffeur est en ligne
  const refreshPool = useCallback(async () => {
    const position = await getPosition();
    const { data, error } = await supabase.rpc("get_localized_pool_for_driver", { _lat: position?.lat ?? null as unknown as number, _lng: position?.lng ?? null as unknown as number, _radius_km: null as unknown as number });
    if (error) {
      if (error.message.includes("Abonnement")) patchState({ accessActive: false, isOnline: false });
      return;
    }
    const rows = data ?? [];
    const fresh = rows.some((row) => !seenRideIds.current.has(row.id));
    if (fresh && poolPrimed.current) chimes.newRide();
    rows.forEach((row) => seenRideIds.current.add(row.id));
    poolPrimed.current = true;
    setOffers(rows.map((row) => ({ id: row.id, client: "", phone: "", distance: row.distance_km, pickup: row.pickup_location, destination: row.dropoff_location, payment: row.payment_method, airConditioning: row.wants_ac, price: row.price_proposed })));
  }, [patchState]);

  const negotiating = state.activeRides.find((ride) => ride.status === "negotiating") ?? null;
  const onboard = state.activeRides.filter((ride) => ride.status === "onboard");
  const anchorRide = state.activeRides.find((ride) => ride.anchor) ?? null;
  const canShare = state.activeRides.length === 0 || (!negotiating && Boolean(anchorRide?.sharing) && anchorRide?.status === "onboard" && state.activeRides.length < MAX_SEATS);

  useEffect(() => {
    if (!isApproved || !state.accessActive || !state.isOnline || negotiating || !canShare || !networkOnline) return;
    void refreshPool();
    const interval = window.setInterval(() => void refreshPool(), POOL_REFRESH_MS);
    return () => window.clearInterval(interval);
  }, [isApproved, networkOnline, refreshPool, state.accessActive, state.isOnline, negotiating, canShare]);

  // Position partagée toutes les 20 s pendant une course : alimente le temps d'arrivée affiché au client
  const lockedId = negotiating?.id;
  useEffect(() => {
    if (!lockedId || !networkOnline) return;
    let arrived = false;
    const send = async () => {
      const position = await getPosition();
      if (!position) return;
      const { data: eta } = await supabase.rpc("update_driver_position", { _lat: position.lat, _lng: position.lng });
      if (!arrived && typeof eta === "number" && eta <= 2) {
        arrived = true;
        chimes.arrived();
        setNotice("Vous êtes arrivé au point de prise en charge.");
      }
    };
    void send();
    const interval = window.setInterval(() => void send(), 20_000);
    return () => window.clearInterval(interval);
  }, [lockedId, networkOnline]);

  async function updateAvailability(update: Partial<Pick<PersistedDriverState, "isOnline" | "airConditioning">>) {
    const next = { isOnline: update.isOnline ?? state.isOnline, airConditioning: update.airConditioning ?? state.airConditioning };
    patchState(next);
    const { error } = await supabase.rpc("set_driver_availability", { _online: next.isOnline, _has_ac: next.airConditioning });
    if (error) setNotice("Réglage conservé sur l’appareil, synchronisation au retour du réseau.");
    else if (next.isOnline) void refreshPool();
  }

  async function activateDay() {
    setBusy(true);
    const { error } = await supabase.rpc("activate_driver_day");
    setBusy(false);
    if (error) return setNotice(friendlyError(error.message));
    patchState({ accessActive: true });
    setNotice("Journée activée jusqu’à 23h59.");
  }

  async function takeRide(id: string) {
    setBusy(true);
    const { data, error } = await supabase.rpc("take_ride", { _ride_id: id });
    setBusy(false);
    const row = data?.[0];
    if (error || !row) {
      setNotice(friendlyError(error?.message));
      void refreshPool();
      return;
    }
    setOffers([]);
    await loadDriver();
  }

  async function finishRide(success: boolean) {
    if (!negotiating) return;
    setBusy(true);
    const { error } = await supabase.rpc("close_ride", { _ride_id: negotiating.id, _success: success });
    setBusy(false);
    if (error) return setNotice(friendlyError(error.message));
    await loadDriver();
    setNotice(success ? "Client à bord. Déposez-le à destination pour clôturer la course." : "Discussion annulée. La demande retourne dans le pool.");
  }

  async function dropOff(id: string) {
    setBusy(true);
    const { error } = await supabase.rpc("drop_off_ride", { _ride_id: id });
    setBusy(false);
    if (error) return setNotice(friendlyError(error.message));
    await loadDriver();
    setNotice("Passager déposé. Course enregistrée au registre.");
  }

  const header = (
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
  );

  let body: React.ReactNode;
  if (user && driver && view === "dossier") {
    body = <DriverOnboarding userId={user.id} onNotice={setNotice} />;
  } else if (loading || (user && driver === undefined)) {
    body = <GateCard icon={<RefreshCw className="size-7 animate-spin" />} title="Chargement de votre poste…" />;
  } else if (!user) {
    body = <GateCard icon={<ShieldCheck className="size-7" />} title="Connectez-vous pour conduire." text="Votre compte chauffeur sécurise vos courses et votre abonnement du jour."><Button asChild className="mt-6 h-12 w-full font-bold shadow-gold"><Link to="/connexion" search={{ retour: "/chauffeur" }}>Se connecter</Link></Button></GateCard>;
  } else if (!driver) {
    body = <RegistrationForm userId={user.id} onDone={loadDriver} />;
  } else if (!isApproved) {
    body = <GateCard icon={<Clock3 className="size-7" />} title={driver.status === "suspended" ? "Compte suspendu." : "Dossier en cours de validation."} text={driver.status === "suspended" ? "Contactez l’administration Allo Taxi..?." : `Merci ${driver.first_name}. L’administration vérifie votre véhicule et votre plaque avant votre première course.`} />;
  } else {
    body = (
      <section className="relative mt-6">
        {state.accessActive && (
          <div className="flex min-h-12 items-center gap-3 rounded-md border border-primary/35 bg-primary px-4 py-3 text-primary-foreground shadow-gold">
            <p className="flex min-w-0 items-center gap-2 text-xs font-black uppercase sm:text-sm"><Sparkles className="size-4 shrink-0" />Accès actif — Expire à 23h59</p>
          </div>
        )}

        <div className={cn("mt-5 space-y-5 transition duration-700", !state.accessActive && "pointer-events-none select-none blur-md")} aria-hidden={!state.accessActive}>
          <ActivationDashboard state={state} onPatch={(update) => void updateAvailability(update)} />
          {onboard.length > 0 && <OnboardPanel rides={onboard} anchor={anchorRide} seatsLeft={MAX_SEATS - state.activeRides.length} busy={busy} onDropOff={(id) => void dropOff(id)} />}
          {negotiating ? (
            <NegotiationScreen ride={negotiating} busy={busy} onFinish={(success) => void finishRide(success)} />
          ) : !state.isOnline ? (
            <OfflinePanel />
          ) : canShare ? (
            <RidePool offers={offers} airConditioning={state.airConditioning} busy={busy} shared={state.activeRides.length > 0} onTake={(id) => void takeRide(id)} />
          ) : null}
        </div>

        {!state.accessActive && (
          <div className="absolute inset-0 z-20 grid min-h-[560px] place-items-center bg-background/55 px-5 backdrop-blur-md">
            <div className="max-w-sm text-center">
              <div className="mx-auto grid size-14 place-items-center rounded-md border border-primary/30 bg-primary/10 text-primary"><ShieldCheck className="size-7" /></div>
              <p className="mt-5 text-xs font-semibold uppercase text-primary">Journée non activée</p>
              <h1 className="mt-2 text-2xl font-semibold">Activez votre accès pour recevoir des courses.</h1>
              <p className="mt-3 text-sm leading-6 text-muted-foreground">Activation valable jusqu’à 23h59, même en cas de coupure momentanée.</p>
              <Button type="button" disabled={busy} onClick={() => void activateDay()} className="mt-6 h-14 w-full text-sm font-bold shadow-gold"><Banknote />Activer ma journée — 1 000 FCFA via Xfin</Button>
            </div>
          </div>
        )}
      </section>
    );
  }

  return (
    <main className="relative min-h-svh overflow-hidden bg-background px-4 py-5 text-foreground sm:px-6 sm:py-8">
      <div className="taxi-grid pointer-events-none absolute inset-0" />
      <div className="relative mx-auto w-full max-w-4xl">
        {header}
        {!networkOnline && (
          <div className="mt-5 flex items-center gap-3 rounded-md border border-primary/30 bg-primary/10 px-4 py-3 text-xs text-primary" role="status">
            <RefreshCw className="size-4 shrink-0" />Vos réglages et votre course en cours restent disponibles sur cet appareil.
          </div>
        )}
        {notice && (
          <div className="mt-5 flex items-center gap-3 rounded-md border border-live/30 bg-live/10 px-4 py-3 text-sm text-live" role="status">
            <CheckCircle2 className="size-4 shrink-0" />{notice}
          </div>
        )}
        {body}
      </div>
    </main>
  );
}

function GateCard({ icon, title, text, children }: { icon: React.ReactNode; title: string; text?: string; children?: React.ReactNode }) {
  return (
    <section className="glass-panel mx-auto mt-10 max-w-md p-8 text-center">
      <div className="mx-auto grid size-14 place-items-center rounded-md border border-primary/30 bg-primary/10 text-primary">{icon}</div>
      <h1 className="mt-5 text-2xl font-semibold">{title}</h1>
      {text && <p className="mt-3 text-sm leading-6 text-muted-foreground">{text}</p>}
      {children}
    </section>
  );
}

function RegistrationForm({ userId, onDone }: { userId: string; onDone: () => void }) {
  const [form, setForm] = useState({ first_name: "", phone: "+241", vehicle_model: "", vehicle_plate: "", has_ac: true });
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(event: FormEvent) {
    event.preventDefault();
    const parsed = registrationSchema.safeParse({ ...form, phone: form.phone.replace(/[\s-]/g, "") });
    if (!parsed.success) return setError(parsed.error.issues[0]?.message ?? "Champs invalides.");
    setBusy(true);
    const { error: insertError } = await supabase.from("drivers").insert({ user_id: userId, ...parsed.data, vehicle_plate: parsed.data.vehicle_plate.toUpperCase(), has_ac: form.has_ac });
    setBusy(false);
    if (insertError) return setError("Enregistrement impossible. Réessayez.");
    onDone();
  }

  return (
    <section className="glass-panel mx-auto mt-8 max-w-lg p-6 sm:p-8">
      <p className="text-xs font-semibold uppercase text-primary">Nouveau chauffeur</p>
      <h1 className="mt-2 text-2xl font-semibold">Déclarez votre véhicule</h1>
      <p className="mt-2 text-sm text-muted-foreground">Votre dossier sera validé par l’administration avant votre première course.</p>
      <form onSubmit={submit} className="mt-6 grid gap-4" noValidate>
        <label className="block"><span className="mb-2 block text-xs font-medium">Prénom</span><Input value={form.first_name} onChange={(e) => setForm({ ...form, first_name: e.target.value })} maxLength={40} className="h-12" /></label>
        <label className="block"><span className="mb-2 block text-xs font-medium">Téléphone WhatsApp</span><Input type="tel" inputMode="tel" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} maxLength={16} className="h-12" /></label>
        <div className="grid gap-4 sm:grid-cols-2">
          <label className="block"><span className="mb-2 block text-xs font-medium">Modèle du véhicule</span><Input value={form.vehicle_model} onChange={(e) => setForm({ ...form, vehicle_model: e.target.value })} placeholder="Toyota Corolla" maxLength={60} className="h-12" /></label>
          <label className="block"><span className="mb-2 block text-xs font-medium">Plaque d’immatriculation</span><Input value={form.vehicle_plate} onChange={(e) => setForm({ ...form, vehicle_plate: e.target.value })} placeholder="1234 G 1A" maxLength={15} className="h-12 uppercase" /></label>
        </div>
        <label className="flex items-center justify-between gap-4 rounded-md border border-border bg-secondary/60 p-4"><span className="flex items-center gap-2 text-sm"><Snowflake className="size-4 text-primary" />Climatisation fonctionnelle</span><Switch checked={form.has_ac} onCheckedChange={(checked) => setForm({ ...form, has_ac: checked })} aria-label="Climatisation fonctionnelle" /></label>
        {error && <p className="text-xs text-destructive" role="alert">{error}</p>}
        <Button type="submit" disabled={busy} className="h-12 w-full font-bold shadow-gold">Envoyer mon dossier</Button>
      </form>
    </section>
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

function OnboardPanel({ rides, anchor, seatsLeft, busy, onDropOff }: { rides: ActiveRide[]; anchor: ActiveRide | null; seatsLeft: number; busy: boolean; onDropOff: (id: string) => void }) {
  const locked = !anchor?.sharing;
  return (
    <section className="glass-panel animate-journey-in overflow-hidden">
      <div className="border-b border-primary/30 bg-primary/10 px-5 py-4 text-xs font-bold uppercase text-primary">
        <span className="flex items-center gap-2"><RouteIcon className="size-4" />Trajet verrouillé{anchor ? ` vers ${anchor.destination}` : ""}</span>
      </div>
      <div className="space-y-4 p-5 sm:p-6">
        <p className="text-xs leading-5 text-muted-foreground">
          {locked
            ? "Le client principal n’a pas accepté le partage : aucune autre course ne vous sera proposée avant sa dépose."
            : seatsLeft > 0
              ? `Partage accepté par le client principal. Seules les courses dans la même direction vous sont proposées (${seatsLeft} place${seatsLeft > 1 ? "s" : ""} restante${seatsLeft > 1 ? "s" : ""}).`
              : "Véhicule complet : 3 passagers à bord."}
        </p>
        {rides.map((ride) => (
          <div key={ride.id} className="flex flex-wrap items-center justify-between gap-3 rounded-md border border-border bg-background/35 p-4">
            <div className="min-w-0">
              <p className="flex items-center gap-2 text-sm font-semibold"><Users className="size-4 text-primary" />{ride.client}{ride.anchor && <span className="rounded border border-primary/30 px-1.5 text-[10px] text-primary">Principal</span>}</p>
              <p className="mt-1 truncate text-xs text-muted-foreground">{ride.pickup} → {ride.destination} · {ride.price.toLocaleString("fr-FR")} FCFA</p>
            </div>
            <Button type="button" disabled={busy} onClick={() => onDropOff(ride.id)} className="h-10 bg-live text-xs font-bold text-foreground hover:bg-live/90"><Flag />Déposé à destination</Button>
          </div>
        ))}
      </div>
    </section>
  );
}

function RidePool({ offers, airConditioning, busy, shared = false, onTake }: { offers: RideOffer[]; airConditioning: boolean; busy: boolean; shared?: boolean; onTake: (id: string) => void }) {
  return (
    <section className="animate-journey-in">
      <div className="mb-4 flex items-end justify-between gap-4">
        <div><p className="text-xs font-semibold uppercase text-live">Flux en direct</p><h1 className="mt-1 text-2xl font-semibold">{shared ? "Passagers sur votre trajet" : "Courses à proximité"}</h1></div>
        <span className="shrink-0 rounded-md border border-border bg-secondary px-3 py-1.5 text-[10px] text-muted-foreground">{offers.length} disponibles</span>
      </div>
      {!airConditioning && <p className="mb-4 flex items-center gap-2 text-xs text-muted-foreground"><Wind className="size-4 text-primary" />Les demandes exigeant la climatisation sont masquées.</p>}
      {offers.length === 0 && <p className="glass-panel p-6 text-center text-sm text-muted-foreground">{shared ? "Aucun passager dans votre direction pour l’instant." : "Aucune demande dans un rayon de 5 km."} Actualisation automatique toutes les 10 secondes.</p>}
      <div className="space-y-4">
        {offers.map((ride) => <RideCard key={ride.id} ride={ride} busy={busy} onTake={() => onTake(ride.id)} />)}
      </div>
    </section>
  );
}

function distanceLabel(distance: number | null) {
  return distance === null ? "Position non partagée" : `À ${distance.toFixed(1)} km de vous`;
}

function RideCard({ ride, busy, onTake }: { ride: RideOffer; busy: boolean; onTake: () => void }) {
  return (
    <article className="glass-panel p-5 sm:p-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <span className="inline-flex items-center gap-1.5 rounded-md border border-primary/30 bg-primary/10 px-2.5 py-1.5 text-[11px] font-semibold text-primary"><MapPin className="size-3.5" />{distanceLabel(ride.distance)}</span>
        <div className="text-right"><p className="text-[10px] uppercase text-muted-foreground">Prix proposé</p><p className="mt-1 text-2xl font-black text-primary">{ride.price.toLocaleString("fr-FR")} <span className="text-sm">FCFA</span></p></div>
      </div>
      <RouteDetails ride={ride} />
      <div className="mt-5 flex flex-wrap items-center justify-between gap-3 border-t border-border pt-4">
        <div className="flex flex-wrap gap-2">
          <RequirementBadge icon={<Banknote />} label={ride.payment} />
          <RequirementBadge icon={ride.airConditioning ? <Snowflake /> : <Wind />} label={ride.airConditioning ? "Climatisation exigée" : "Standard"} highlight={ride.airConditioning} />
        </div>
        <Button type="button" disabled={busy} onClick={onTake} className="h-11 w-full px-7 font-bold shadow-gold sm:w-auto">Prendre <Navigation /></Button>
      </div>
    </article>
  );
}

function NegotiationScreen({ ride, busy, onFinish }: { ride: RideOffer; busy: boolean; onFinish: (success: boolean) => void }) {
  const message = encodeURIComponent(`Bonjour ${ride.client}, je suis votre chauffeur Allo Taxi..? Je souhaite confirmer votre trajet de ${ride.pickup} vers ${ride.destination}, au tarif proposé de ${ride.price.toLocaleString("fr-FR")} FCFA, règlement ${ride.payment}${ride.airConditioning ? ", avec climatisation" : ""}. Où puis-je vous retrouver précisément ?`);
  return (
    <section className="glass-panel animate-journey-in overflow-hidden">
      <div className="border-b border-live/25 bg-live/10 px-5 py-4 text-center text-xs font-bold uppercase text-live"><span className="mr-2 inline-block size-2 rounded-full bg-live" />Course verrouillée — Discussion en cours</div>
      <div className="p-5 sm:p-8">
        <div className="text-center">
          <div className="mx-auto grid size-14 place-items-center rounded-md bg-primary/10 text-primary"><UserRound className="size-7" /></div>
          <p className="mt-4 text-xs font-semibold uppercase text-primary">Client à contacter</p>
          <h1 className="mt-2 text-3xl font-semibold">{ride.client}</h1>
          <p className="mt-2 text-sm text-muted-foreground">{distanceLabel(ride.distance)} · Offre à {ride.price.toLocaleString("fr-FR")} FCFA</p>
        </div>

        <RouteDetails ride={ride} prominent />

        <div className="mt-5 flex flex-wrap justify-center gap-2">
          <RequirementBadge icon={<Banknote />} label={ride.payment} />
          <RequirementBadge icon={ride.airConditioning ? <Snowflake /> : <Wind />} label={ride.airConditioning ? "Climatisation exigée" : "Standard"} highlight={ride.airConditioning} />
        </div>

        <Button asChild className="mt-6 h-14 w-full bg-live text-sm font-bold text-foreground shadow-live hover:bg-live/90">
          <a href={`https://wa.me/${ride.phone.replace(/\D/g, "")}?text=${message}`} target="_blank" rel="noreferrer"><Phone />Ouvrir WhatsApp pour négocier</a>
        </Button>

        <div className="mt-7 border-t border-border pt-5">
          <p className="mb-4 text-center text-xs leading-5 text-muted-foreground">Clôturez obligatoirement la discussion pour recevoir une nouvelle course. Sans clôture sous 15 minutes, la course est libérée et une pénalité est enregistrée.</p>
          <div className="grid gap-3 sm:grid-cols-2">
            <Button type="button" disabled={busy} variant="outline" onClick={() => onFinish(false)} className="min-h-12 whitespace-normal border-destructive/40 text-xs text-destructive hover:bg-destructive/10 hover:text-destructive"><XCircle />Annuler — Échec de la discussion</Button>
            <Button type="button" disabled={busy} onClick={() => onFinish(true)} className="min-h-12 whitespace-normal bg-live text-xs font-bold text-foreground hover:bg-live/90"><CheckCircle2 />Embarqué — Course validée</Button>
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