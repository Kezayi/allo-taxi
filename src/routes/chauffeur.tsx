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
import { DriverOnboarding } from "@/components/driver/onboarding";
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
const paymentLabels: Record<string, string> = { CASH: "Espèces", AIRTEL_MONEY: "Airtel Money", MOOV_MONEY: "Moov Money" };
const paymentLabel = (p: string) => paymentLabels[p] ?? p;

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
  landmark?: string | null;
  dropoffNote?: string | null;
  passengers?: number | null;
  sharing?: boolean;
};

/** Course legacy publiée avant LOT 4B : conservée uniquement pour être menée à son terme. */
type ActiveRide = RideOffer & { status: "negotiating" | "onboard"; sharing: boolean; anchor: boolean };

type V1Status = "CONTACT_PENDING" | "CONFIRMED" | "DRIVER_EN_ROUTE" | "DRIVER_ARRIVED" | "ONBOARD";
/** Course V1 en cours : projection serveur get_my_active_rides, sans téléphone du client. */
type V1Ride = {
  ride_id: string;
  status: V1Status;
  client_first_name: string;
  pickup_location: string;
  pickup_landmark: string | null;
  dropoff_location: string;
  dropoff_note: string | null;
  passenger_count: number | null;
  wants_ac: boolean;
  allow_sharing: boolean;
  payment_method: string | null;
  price_proposed: number;
  price_final: number | null;
};

type PersistedDriverState = {
  accessActive: boolean;
  isOnline: boolean;
  airConditioning: boolean;
  activeRides: ActiveRide[];
  /** Courses V1 actives : plusieurs en cas de partage, chacune indépendante. */
  v1Rides: V1Ride[];
};

/** État de partage calculé par le serveur (get_my_shared_state_v1). */
type SharedState = {
  passenger_capacity: number | null;
  seats_engaged: number;
  seats_onboard: number;
  active_rides: number;
  accepting_new_shared: boolean;
  detour_threshold_set: boolean;
};

type DriverRow = { status: string; first_name: string; has_ac: boolean };

const STORAGE_KEY = "allo-taxi-driver-workspace-v4";
/** Compatibilité legacy uniquement (courses antérieures au LOT 4B). Jamais utilisé pour les courses V1. */
const LEGACY_MAX_SEATS = 3;
const POOL_REFRESH_MS = 10000;
const ACTIVE_REFRESH_MS = 6000;

const defaultState: PersistedDriverState = { accessActive: false, isOnline: false, airConditioning: true, activeRides: [], v1Rides: [] };

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
  if (message.includes("RIDE_UNAVAILABLE") || message.includes("déjà prise")) return "Cette course vient d’être prise par un autre chauffeur ou n’est plus disponible.";
  if (message.includes("DRIVER_ALREADY_ENGAGED")) return "Terminez d’abord votre course en cours.";
  if (message.includes("SHARING_NOT_ALLOWED")) return "Partage impossible : un client n’a pas accepté le partage.";
  if (message.includes("SHARED_WAIT_ONBOARD")) return "Embarquez d’abord votre premier client avant d’accepter un autre passager.";
  if (message.includes("SHARED_CLOSED")) return "Vous avez fermé les nouvelles propositions partagées.";
  if (message.includes("DIRECTION_INCOMPATIBLE")) return "Cette course n’est pas dans votre direction.";
  if (message.includes("DETOUR_EXCEEDED")) return "Cette course impose un détour trop important.";
  if (message.includes("SHARED_DETOUR_THRESHOLD_REQUIRED")) return "Le partage n’est pas encore ouvert par l’administration.";
  if (message.includes("CAPACITY_EXCEEDED")) return "Places insuffisantes dans votre véhicule.";
  if (message.includes("CAPACITY_UNKNOWN")) return "Capacité du véhicule non validée : partage impossible.";
  if (message.includes("RIDE_REQUIRES_AC")) return "Cette course demande un véhicule climatisé.";
  if (message.includes("DRIVER_OFFLINE")) return "Passez en ligne pour prendre une course.";
  if (message.includes("DAY_ACCESS_REQUIRED")) return "Activez votre accès du jour pour recevoir des courses.";
  if (message.includes("DOCUMENTS") || message.includes("ELIGIB")) return "Votre dossier doit être complété avant de prendre des courses.";
  if (message.includes("REASON_REQUIRED")) return "Indiquez un motif d’au moins 3 caractères.";
  if (message.includes("NOT_ALLOWED") || message.includes("NOT_ASSIGNED")) return "Action impossible : la course a changé d’état.";
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
  const [ticket, setTicket] = useState<{ mode: "FREE" | "PAID"; price: number; xfin: boolean }>({ mode: "FREE", price: 1000, xfin: false });
  const [view, setView] = useState<"poste" | "dossier">("poste");
  const [shared, setShared] = useState<SharedState | null>(null);

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
    // Ticket journalier V1 : driver_day_passes est la seule référence (plus de lecture de subscriptions)
    // Courses en cours : projection serveur (plus de lecture directe de la table des courses)
    const [{ data: access }, { data: current, error: currentError }, { data: sharedData, error: sharedError }] = await Promise.all([
      supabase.rpc("get_my_driver_day_access"),
      supabase.rpc("get_my_active_rides"),
      supabase.rpc("get_my_shared_state_v1"),
    ]);
    if (!sharedError && sharedData) setShared(sharedData as unknown as SharedState);
    const acc = (access ?? {}) as { access_valid?: boolean; ticket_mode?: string; ticket_price_fcfa?: number; xfin_configured?: boolean };
    const valid = Boolean(acc.access_valid);
    setTicket({ mode: acc.ticket_mode === "PAID" ? "PAID" : "FREE", price: acc.ticket_price_fcfa ?? 1000, xfin: Boolean(acc.xfin_configured) });
    const rows = (currentError ? null : (current as unknown as Array<Record<string, unknown>> | null)) ?? null;
    patchState({
      accessActive: valid,
      airConditioning: data.has_ac,
      ...(valid ? {} : { isOnline: false }),
      ...(rows ? {
        v1Rides: rows.filter((r) => r["workflow_version"] === "v1") as unknown as V1Ride[],
        activeRides: rows.filter((r) => r["workflow_version"] === "legacy").map((r) => ({
          id: String(r["ride_id"]), client: String(r["client_first_name"] ?? ""), phone: String(r["client_phone"] ?? ""), distance: null,
          pickup: String(r["pickup_location"]), destination: String(r["dropoff_location"]), payment: String(r["payment_method"] ?? ""),
          airConditioning: Boolean(r["wants_ac"]), price: Number(r["price_proposed"]),
          status: r["status"] === "onboard" ? "onboard" as const : "negotiating" as const, sharing: Boolean(r["allow_sharing"]), anchor: Boolean(r["is_anchor"]),
        })),
      } : {}),
    });
  }, [patchState, user]);

  useEffect(() => { void loadDriver(); }, [loadDriver]);

  // Pool V1 : uniquement les nouvelles courses V1, projection sans identité ni téléphone du client
  const refreshPool = useCallback(async () => {
    const position = await getPosition();
    const { data, error } = await supabase.rpc("get_pool_v1", { _lat: position?.lat ?? null as unknown as number, _lng: position?.lng ?? null as unknown as number, _radius_km: null as unknown as number });
    if (error) {
      if (error.message.includes("DAY_ACCESS_REQUIRED")) patchState({ accessActive: false, isOnline: false });
      return;
    }
    const rows = data ?? [];
    const fresh = rows.some((row) => !seenRideIds.current.has(row.ride_id));
    if (fresh && poolPrimed.current) chimes.newRide();
    rows.forEach((row) => seenRideIds.current.add(row.ride_id));
    poolPrimed.current = true;
    setOffers(rows.map((row) => ({ id: row.ride_id, client: "", phone: "", distance: row.distance_km, pickup: row.pickup_location, destination: row.dropoff_location, payment: row.payment_method, airConditioning: row.wants_ac, price: row.price_proposed, landmark: row.pickup_landmark, dropoffNote: row.dropoff_note, passengers: row.passenger_count, sharing: row.allow_sharing })));
  }, [patchState]);

  const negotiating = state.activeRides.find((ride) => ride.status === "negotiating") ?? null;
  const onboard = state.activeRides.filter((ride) => ride.status === "onboard");
  const anchorRide = state.activeRides.find((ride) => ride.anchor) ?? null;
  const v1Rides = state.v1Rides ?? [];
  const engaged = state.activeRides.length > 0 || v1Rides.length > 0;
  // Le pool reste interrogé quand un partage est possible ; le serveur seul décide de la compatibilité.
  const sharedPoolOpen = state.activeRides.length === 0 && v1Rides.length > 0 && v1Rides.some((r) => r.status === "ONBOARD") && v1Rides.every((r) => r.allow_sharing) && Boolean(shared?.accepting_new_shared);
  const poolActive = (!engaged || sharedPoolOpen);

  useEffect(() => {
    if (!isApproved || !state.accessActive || !state.isOnline || !poolActive || !networkOnline) return;
    void refreshPool();
    const interval = window.setInterval(() => void refreshPool(), POOL_REFRESH_MS);
    return () => window.clearInterval(interval);
  }, [isApproved, networkOnline, refreshPool, state.accessActive, state.isOnline, poolActive]);

  // Course en cours : l'état serveur fait foi (le client peut confirmer, refuser ou annuler à tout moment)
  useEffect(() => {
    if (!isApproved || !engaged || !networkOnline) return;
    const interval = window.setInterval(() => void loadDriver(), ACTIVE_REFRESH_MS);
    return () => window.clearInterval(interval);
  }, [isApproved, engaged, networkOnline, loadDriver]);

  const prevV1 = useRef<Map<string, V1Status> | null>(null);
  useEffect(() => {
    const prev = prevV1.current;
    const cur = new Map(v1Rides.map((r) => [r.ride_id, r.status] as const));
    if (prev && hydrated) {
      for (const [id, status] of cur) {
        if (prev.get(id) === "CONTACT_PENDING" && status === "CONFIRMED") { chimes.accepted(); setNotice("Le client a confirmé la course."); }
      }
      for (const id of prev.keys()) if (!cur.has(id)) setNotice("Une course n’est plus active (terminée, annulée ou relâchée).");
    }
    prevV1.current = cur;
  }, [v1Rides, hydrated]);

  async function toggleAcceptingShared(on: boolean) {
    setShared((s) => (s ? { ...s, accepting_new_shared: on } : s));
    const { error } = await supabase.rpc("set_accepting_new_shared_v1", { _on: on });
    if (error) setNotice(friendlyError(error.message));
    else setNotice(on ? "Nouveaux passagers partagés acceptés." : "Nouvelles propositions partagées fermées. Vos courses continuent.");
    await loadDriver();
  }

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
    const { error } = await supabase.rpc("activate_my_driver_day_v1", { _payment_msisdn: null as unknown as string });
    setBusy(false);
    if (error) {
      if (error.message.includes("XFIN_NOT_CONFIGURED")) return setNotice("Paiement du ticket indisponible pour le moment. Réessayez plus tard.");
      return setNotice(friendlyError(error.message));
    }
    patchState({ accessActive: true });
    setNotice("Accès actif jusqu’à minuit — aucun paiement requis.");
  }

  async function takeRide(id: string) {
    setBusy(true);
    const { error } = await supabase.rpc("reserve_ride_v1", { _ride_id: id });
    setBusy(false);
    if (error) {
      setNotice(friendlyError(error.message));
      void refreshPool();
      return;
    }
    setOffers([]);
    await loadDriver();
    setNotice("Course réservée. Le client va vous contacter sur WhatsApp.");
  }

  async function runV1(fn: () => PromiseLike<{ error: { message: string } | null }>, success: string) {
    setBusy(true);
    const { error } = await fn();
    setBusy(false);
    await loadDriver();
    if (error) return setNotice(friendlyError(error.message));
    setNotice(success);
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
          {v1Rides.length > 0 ? (
            <>
              <SharedPanel rides={v1Rides} shared={shared} onToggle={(on) => void toggleAcceptingShared(on)} />
              {v1Rides.map((ride) => (
                <V1RideScreen
                  key={ride.ride_id}
                  ride={ride}
                  busy={busy}
                  onAdvance={(action, success) => void runV1(() => supabase.rpc("advance_ride_v1", { _ride_id: ride.ride_id, _action: action }), success)}
                  onRelease={(reason) => void runV1(() => supabase.rpc("release_ride_v1", { _ride_id: ride.ride_id, _reason: reason as unknown as string }), "Course relâchée : elle retourne aux autres chauffeurs.")}
                  onCancel={(reason) => void runV1(() => supabase.rpc("cancel_ride_by_driver_v1", { _ride_id: ride.ride_id, _reason: reason }), "Course annulée. Le client est informé sur son écran.")}
                />
              ))}
              {sharedPoolOpen && state.isOnline && <RidePool offers={offers} airConditioning={state.airConditioning} busy={busy} shared onTake={(id) => void takeRide(id)} />}
            </>
          ) : (
            <>
              {/* Compatibilité : course legacy acceptée avant la mise à jour, menée à son terme puis plus jamais proposée */}
              {onboard.length > 0 && <OnboardPanel rides={onboard} anchor={anchorRide} seatsLeft={LEGACY_MAX_SEATS - state.activeRides.length} busy={busy} onDropOff={(id) => void dropOff(id)} />}
              {negotiating ? (
                <NegotiationScreen ride={negotiating} busy={busy} onFinish={(success) => void finishRide(success)} />
              ) : !state.isOnline ? (
                <OfflinePanel />
              ) : !engaged ? (
                <RidePool offers={offers} airConditioning={state.airConditioning} busy={busy} onTake={(id) => void takeRide(id)} />
              ) : null}
            </>
          )}
        </div>

        {!state.accessActive && (
          <div className="absolute inset-0 z-20 grid min-h-[560px] place-items-center bg-background/55 px-5 backdrop-blur-md">
            <div className="max-w-sm text-center">
              <div className="mx-auto grid size-14 place-items-center rounded-md border border-primary/30 bg-primary/10 text-primary"><ShieldCheck className="size-7" /></div>
              {ticket.mode === "FREE" ? (
                <>
                  <p className="mt-5 text-xs font-semibold uppercase text-live">Accès journée offert</p>
                  <h1 className="mt-2 text-2xl font-semibold">0 FCFA aujourd’hui</h1>
                  <p className="mt-3 text-sm leading-6 text-muted-foreground">Aucun paiement requis. Accès valable jusqu’à minuit (heure de Libreville).</p>
                  <p className="mt-1 text-[11px] text-muted-foreground">Tarif standard : {ticket.price.toLocaleString("fr-FR")} FCFA — non facturé aujourd’hui.</p>
                  <Button type="button" disabled={busy} onClick={() => void activateDay()} className="mt-6 h-14 w-full text-sm font-bold shadow-gold"><ShieldCheck />Activer mon accès aujourd’hui</Button>
                </>
              ) : (
                <>
                  <p className="mt-5 text-xs font-semibold uppercase text-primary">Ticket journalier payant</p>
                  <h1 className="mt-2 text-2xl font-semibold">Paiement indisponible pour le moment.</h1>
                  <p className="mt-3 text-sm leading-6 text-muted-foreground">Le paiement en ligne n’est pas encore ouvert. Contactez l’administration.</p>
                </>
              )}
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
        {user && driver && (
          <nav aria-label="Sections chauffeur" className="mt-5 flex gap-2 rounded-md border border-border bg-secondary/60 p-1">
            {([["poste", "Poste de conduite"], ["dossier", "Mon dossier"]] as const).map(([id, label]) => (
              <button key={id} type="button" onClick={() => setView(id)} aria-current={view === id}
                className={cn("h-10 flex-1 rounded-md text-xs font-semibold transition-colors", view === id ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:text-foreground")}>
                {label}
              </button>
            ))}
          </nav>
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
          <RequirementBadge icon={<Banknote />} label={paymentLabel(ride.payment)} />
          {ride.passengers != null && <RequirementBadge icon={<Users />} label={`${ride.passengers} passager(s)`} />}
          <RequirementBadge icon={ride.airConditioning ? <Snowflake /> : <Wind />} label={ride.airConditioning ? "Climatisation exigée" : "Standard"} highlight={ride.airConditioning} />
        </div>
        <Button type="button" disabled={busy} onClick={onTake} className="h-11 w-full px-7 font-bold shadow-gold sm:w-auto">Réserver <Navigation /></Button>
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

/** Taxi partagé V1 : places engagées / capacité homologuée et interrupteur des nouvelles propositions. */
function SharedPanel({ rides, shared, onToggle }: { rides: V1Ride[]; shared: SharedState | null; onToggle: (on: boolean) => void }) {
  const allSharing = rides.every((r) => r.allow_sharing);
  const hasOnboard = rides.some((r) => r.status === "ONBOARD");
  const cap = shared?.passenger_capacity ?? null;
  const reason = !allSharing
    ? "Un client n’a pas accepté le partage : aucune autre course jusqu’à sa dépose."
    : !hasOnboard
      ? "Le partage s’ouvre une fois le premier client à bord."
      : cap == null
        ? "Capacité du véhicule non validée : partage indisponible."
        : shared && !shared.detour_threshold_set
          ? "Partage pas encore ouvert par l’administration."
          : "Seules les courses compatibles avec votre trajet vous sont proposées.";
  return (
    <section className="glass-panel p-5 sm:p-6">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div>
          <p className="text-xs font-semibold uppercase text-primary">{rides.length > 1 ? `${rides.length} courses en cours` : "Course en cours"}</p>
          <p className="mt-1 text-sm">
            Places engagées : <strong>{shared?.seats_engaged ?? "—"}</strong>{cap != null ? ` / ${cap}` : ""} · à bord : <strong>{shared?.seats_onboard ?? "—"}</strong>
          </p>
          <p className="mt-1 text-xs text-muted-foreground">{reason}</p>
        </div>
        {allSharing && (
          <label className="flex items-center gap-3 text-xs">
            <span>Accepter d’autres passagers</span>
            <Switch checked={Boolean(shared?.accepting_new_shared)} onCheckedChange={onToggle} aria-label="Accepter de nouveaux passagers partagés" />
          </label>
        )}
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
      <span className="grid size-6 place-items-center rounded-full bg-live/15 text-live"><MapPin className="size-3.5" /></span><p className="min-w-0 break-words text-sm"><span className="mb-1 block text-[10px] font-semibold uppercase text-muted-foreground">Départ</span>{ride.pickup}{ride.landmark && <span className="mt-1 block text-xs text-muted-foreground">Repère : {ride.landmark}</span>}</p>
      <span className="grid size-6 place-items-center rounded-full bg-primary/15 text-primary"><Navigation className="size-3.5" /></span><p className="min-w-0 break-words text-sm"><span className="mb-1 block text-[10px] font-semibold uppercase text-muted-foreground">Destination</span>{ride.destination}{ride.dropoffNote && <span className="mt-1 block text-xs text-muted-foreground">{ride.dropoffNote}</span>}</p>
    </div>
  );
}

function RequirementBadge({ icon, label, highlight = false }: { icon: React.ReactNode; label: string; highlight?: boolean }) {
  return <span className={cn("inline-flex items-center gap-1.5 rounded-md border px-2.5 py-1.5 text-[10px] font-semibold [&_svg]:size-3.5", highlight ? "border-primary/30 bg-primary/10 text-primary" : "border-border bg-secondary text-muted-foreground")}>{icon}{label}</span>;
}
const v1Labels: Record<V1Status, string> = {
  CONTACT_PENDING: "En attente du contact client",
  CONFIRMED: "Course confirmée par le client",
  DRIVER_EN_ROUTE: "En route vers le client",
  DRIVER_ARRIVED: "Arrivé au point de départ",
  ONBOARD: "Client à bord",
};

function V1RideScreen({ ride, busy, onAdvance, onRelease, onCancel }: {
  ride: V1Ride;
  busy: boolean;
  onAdvance: (action: "MARK_EN_ROUTE" | "MARK_ARRIVED" | "MARK_ONBOARD" | "MARK_COMPLETED", success: string) => void;
  onRelease: (reason: string | null) => void;
  onCancel: (reason: string) => void;
}) {
  const [cancelOpen, setCancelOpen] = useState(false);
  const [reason, setReason] = useState("");
  const next: Partial<Record<V1Status, { action: "MARK_EN_ROUTE" | "MARK_ARRIVED" | "MARK_ONBOARD" | "MARK_COMPLETED"; label: string; success: string }>> = {
    CONFIRMED: { action: "MARK_EN_ROUTE", label: "Je pars chercher le client", success: "Le client voit que vous êtes en route." },
    DRIVER_EN_ROUTE: { action: "MARK_ARRIVED", label: "Je suis arrivé", success: "Le client est prévenu de votre arrivée." },
    DRIVER_ARRIVED: { action: "MARK_ONBOARD", label: "Client à bord", success: "Bonne route." },
    ONBOARD: { action: "MARK_COMPLETED", label: "Client déposé — terminer", success: "Course terminée." },
  };
  const step = next[ride.status];
  const canCancel = ["CONFIRMED", "DRIVER_EN_ROUTE", "DRIVER_ARRIVED"].includes(ride.status);
  return (
    <section className="glass-panel animate-journey-in overflow-hidden">
      <div className="border-b border-live/25 bg-live/10 px-5 py-4 text-center text-xs font-bold uppercase text-live"><span className="mr-2 inline-block size-2 rounded-full bg-live" />{v1Labels[ride.status]}</div>
      <div className="p-5 sm:p-8">
        <div className="text-center">
          <div className="mx-auto grid size-14 place-items-center rounded-md bg-primary/10 text-primary"><UserRound className="size-7" /></div>
          <h1 className="mt-4 text-3xl font-semibold">{ride.client_first_name}</h1>
          <p className="mt-2 text-sm text-muted-foreground">
            {ride.price_final != null ? <>Prix convenu : <strong className="text-primary">{ride.price_final.toLocaleString("fr-FR")} FCFA</strong></> : <>Prix proposé : {ride.price_proposed.toLocaleString("fr-FR")} FCFA</>}
          </p>
        </div>
        <RouteDetails ride={{ id: ride.ride_id, client: "", phone: "", distance: null, pickup: ride.pickup_location, destination: ride.dropoff_location, payment: ride.payment_method ?? "", airConditioning: ride.wants_ac, price: ride.price_proposed, landmark: ride.pickup_landmark, dropoffNote: ride.dropoff_note }} prominent />
        <div className="mt-5 flex flex-wrap justify-center gap-2">
          <RequirementBadge icon={<Banknote />} label={`${paymentLabel(ride.payment_method ?? "")} — au chauffeur`} />
          <RequirementBadge icon={<Users />} label={`${ride.passenger_count ?? "?"} passager(s)`} />
          <RequirementBadge icon={ride.wants_ac ? <Snowflake /> : <Wind />} label={ride.wants_ac ? "Climatisation souhaitée" : "Standard"} highlight={ride.wants_ac} />
        </div>

        {ride.status === "CONTACT_PENDING" && (
          <div className="mt-6 space-y-3">
            <p className="rounded-md border border-border bg-background/35 p-4 text-center text-xs leading-5 text-muted-foreground">Le client a votre WhatsApp. Il vous écrit pour convenir du prix, puis confirme la course depuis son écran. Allo Taxi ne vous communique pas son numéro.</p>
            <Button type="button" variant="outline" disabled={busy} onClick={() => onRelease(null)} className="h-12 w-full whitespace-normal text-xs"><XCircle />Pas d’accord — relâcher la course</Button>
          </div>
        )}
        {step && <Button type="button" disabled={busy} onClick={() => onAdvance(step.action, step.success)} className="mt-6 h-14 w-full bg-live text-sm font-bold text-foreground shadow-live hover:bg-live/90"><CheckCircle2 />{step.label}</Button>}
        {canCancel && (cancelOpen ? (
          <div className="mt-4 space-y-2 rounded-md border border-destructive/30 p-4">
            <label className="block text-xs font-medium">Motif d’annulation (obligatoire)<Input value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} className="mt-2 h-11" placeholder="Ex : panne du véhicule" /></label>
            <div className="grid grid-cols-2 gap-2">
              <Button type="button" variant="ghost" onClick={() => setCancelOpen(false)}>Retour</Button>
              <Button type="button" variant="destructive" disabled={busy || reason.trim().length < 3} onClick={() => onCancel(reason.trim())}>Annuler la course</Button>
            </div>
          </div>
        ) : (
          <Button type="button" variant="ghost" onClick={() => setCancelOpen(true)} className="mt-3 w-full text-xs text-destructive hover:text-destructive">Annuler la course</Button>
        ))}
      </div>
    </section>
  );
}
