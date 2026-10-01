import { createFileRoute, Link } from "@tanstack/react-router";
import {
  ArrowLeft,
  BadgeCheck,
  CarFront,
  CircleDollarSign,
  Clock3,
  Crosshair,
  Flag,
  MessageCircle,
  Minus,
  Navigation,
  Plus,
  ShieldCheck,
  Snowflake,
  UserRound,
  Users,
  Wind,
  X,
} from "lucide-react";
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { z } from "zod";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { supabase } from "@/integrations/supabase/client";
import { chimes } from "@/lib/chime";
import { cn } from "@/lib/utils";

export const Route = createFileRoute("/client")({
  head: () => ({
    meta: [
      { title: "Course express — Allo Taxi..?" },
      { name: "description", content: "Demandez une course VTC express à Libreville, sans inscription obligatoire." },
      { property: "og:title", content: "Course express — Allo Taxi..?" },
      { property: "og:description", content: "Publiez votre trajet et trouvez un chauffeur à proximité." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: ClientJourney,
});

/* ---------- Modèle ---------- */
type Payment = "CASH" | "AIRTEL_MONEY" | "MOOV_MONEY";
const paymentLabels: Record<Payment, string> = { CASH: "Espèces", AIRTEL_MONEY: "Airtel Money", MOOV_MONEY: "Moov Money" };

type RideForm = {
  firstName: string;
  phone: string;
  pickup: string;
  landmark: string;
  destination: string;
  dropoffNote: string;
  passengers: number | null;
  wantsAc: boolean;
  shared: boolean;
  payment: Payment;
  price: number;
};

const initialForm: RideForm = { firstName: "", phone: "", pickup: "", landmark: "", destination: "", dropoffNote: "", passengers: null, wantsAc: false, shared: false, payment: "CASH", price: 2000 };

const formSchema = z.object({
  firstName: z.string().trim().min(2, "Saisissez au moins 2 caractères.").max(40, "Le prénom est trop long."),
  phone: z.string().trim().refine((v) => /^[0-9]{8,9}$/.test(v.replace(/[\s-]/g, "")), "Saisissez un numéro gabonais valide (8 ou 9 chiffres)."),
  pickup: z.string().trim().min(3, "Précisez votre point de départ.").max(120, "L’adresse est trop longue."),
  landmark: z.string().trim().max(120, "Le repère est trop long."),
  destination: z.string().trim().min(3, "Précisez votre destination.").max(120, "L’adresse est trop longue."),
  dropoffNote: z.string().trim().max(160, "L’indication est trop longue."),
  passengers: z.number({ error: "Indiquez le nombre de passagers." }).int().min(1, "Indiquez le nombre de passagers.").max(8, "8 passagers maximum."),
  wantsAc: z.boolean(),
  shared: z.boolean(),
  payment: z.enum(["CASH", "AIRTEL_MONEY", "MOOV_MONEY"]),
  price: z.number().int().min(500, "Le prix minimum est de 500 FCFA.").max(100000, "Le prix maximum est de 100 000 FCFA."),
});

type V1Status = "PENDING" | "CONTACT_PENDING" | "CONFIRMED" | "DRIVER_EN_ROUTE" | "DRIVER_ARRIVED" | "ONBOARD" | "COMPLETED" | "CANCELED_BY_CLIENT" | "CANCELED_BY_DRIVER" | "CONTACT_FAILED" | "EXPIRED" | "INCIDENT";

type RideStatus = {
  ride_id: string;
  status: V1Status;
  pickup_location: string;
  pickup_landmark: string | null;
  dropoff_location: string;
  dropoff_note: string | null;
  passenger_count: number;
  wants_ac: boolean;
  allow_sharing: boolean;
  payment_method: Payment | null;
  price_proposed: number;
  price_final: number | null;
  contact: { driver_first_name: string; whatsapp_status: "AVAILABLE" | "MISSING" | "INVALID"; whatsapp_url: string | null } | null;
  safety: { driver_first_name: string; driver_photo_url: string | null; vehicle_photo_url: string | null; vehicle_make: string | null; vehicle_model: string | null; vehicle_color: string | null; vehicle_plate: string | null } | null;
};

const statusLabels: Record<V1Status, string> = {
  PENDING: "Recherche d’un chauffeur",
  CONTACT_PENDING: "Mise en relation",
  CONFIRMED: "Course confirmée",
  DRIVER_EN_ROUTE: "Le chauffeur est en route",
  DRIVER_ARRIVED: "Le chauffeur est arrivé",
  ONBOARD: "Course en cours",
  COMPLETED: "Course terminée",
  CANCELED_BY_CLIENT: "Course annulée",
  CANCELED_BY_DRIVER: "Le chauffeur a annulé",
  CONTACT_FAILED: "Mise en relation terminée sans accord",
  EXPIRED: "Demande expirée",
  INCIDENT: "Incident signalé",
};
const TERMINAL: V1Status[] = ["COMPLETED", "CANCELED_BY_CLIENT", "CANCELED_BY_DRIVER", "CONTACT_FAILED", "EXPIRED", "INCIDENT"];
const CLIENT_CANCELABLE: V1Status[] = ["PENDING", "CONTACT_PENDING", "CONFIRMED", "DRIVER_EN_ROUTE", "DRIVER_ARRIVED"];

/* Secret de suivi : sessionStorage (survit au rechargement de l’onglet, jamais affiché, jamais dans l’URL). */
const V1_KEY = "allo-taxi-ride-v1";
const LEGACY_KEY = "allo-taxi-active-ride-v2";
type Session = { id: string; token: string };
const POLL_MS = 5000;

function getPosition(): Promise<{ lat: number; lng: number } | null> {
  return new Promise((resolve) => {
    if (!("geolocation" in navigator)) return resolve(null);
    navigator.geolocation.getCurrentPosition(
      (pos) => resolve({ lat: pos.coords.latitude, lng: pos.coords.longitude }),
      () => resolve(null),
      { enableHighAccuracy: true, timeout: 8000, maximumAge: 60000 },
    );
  });
}

function errorText(message: string | undefined, fallback: string) {
  const m = message ?? "";
  if (m.includes("ACTIVE_RIDE_EXISTS")) return "Une course est déjà en cours avec ce numéro. Terminez-la ou annulez-la avant d’en publier une nouvelle.";
  if (m.includes("RATE_LIMITED")) return "Trop de demandes publiées avec ce numéro en une heure. Réessayez un peu plus tard.";
  if (m.includes("CLIENT_RESTRICTED")) return "Ce numéro ne peut pas publier de demande pour le moment. Contactez Allo Taxi.";
  if (m.includes("INVALID_DATA")) return "Certaines informations sont invalides. Vérifiez votre demande.";
  if (m.includes("INVALID_PRICE")) return "Le prix convenu doit être compris entre 500 et 100 000 FCFA.";
  if (m.includes("NOT_ALLOWED")) return "Cette action n’est plus possible : la course a changé d’état.";
  return typeof navigator !== "undefined" && !navigator.onLine ? "Pas de réseau. Réessayez dès le retour de la connexion." : fallback;
}

/* ---------- Écran principal ---------- */
function ClientJourney() {
  const [session, setSession] = useState<Session | null>(null);
  const [legacy, setLegacy] = useState<Session | null>(null);
  const [status, setStatus] = useState<RideStatus | null>(null);
  const [lost, setLost] = useState(false);
  const [hydrated, setHydrated] = useState(false);
  const lastStatus = useRef<V1Status | null>(null);

  useEffect(() => {
    try {
      const v1 = sessionStorage.getItem(V1_KEY);
      if (v1) setSession(JSON.parse(v1) as Session);
      const old = sessionStorage.getItem(LEGACY_KEY);
      if (old) {
        const parsed = JSON.parse(old) as Session;
        if (parsed?.id && parsed?.token) setLegacy({ id: parsed.id, token: parsed.token });
      }
    } catch {
      sessionStorage.removeItem(V1_KEY);
    }
    setHydrated(true);
  }, []);

  const poll = useCallback(async () => {
    if (!session) return;
    const { data, error } = await supabase.rpc("get_ride_status_v1", { _ride_id: session.id, _token: session.token });
    if (error) return; // coupure réseau : on garde la session locale
    if (!data) { setLost(true); return; }
    const next = data as unknown as RideStatus;
    const prev = lastStatus.current;
    if (prev && prev !== next.status) {
      if (next.status === "CONTACT_PENDING") chimes.accepted();
      if (next.status === "COMPLETED") chimes.finished();
    }
    lastStatus.current = next.status;
    setStatus(next);
  }, [session]);

  useEffect(() => {
    if (!session) return;
    void poll();
    const t = window.setInterval(() => void poll(), POLL_MS);
    return () => window.clearInterval(t);
  }, [poll, session]);

  function startSession(s: Session) {
    sessionStorage.setItem(V1_KEY, JSON.stringify(s));
    lastStatus.current = "PENDING";
    setSession(s);
  }
  function clearSession() {
    sessionStorage.removeItem(V1_KEY);
    lastStatus.current = null;
    setSession(null);
    setStatus(null);
    setLost(false);
  }
  function clearLegacy() {
    sessionStorage.removeItem(LEGACY_KEY);
    setLegacy(null);
  }

  let body: React.ReactNode;
  if (!hydrated) body = null;
  else if (legacy && !session) body = <LegacyTracker session={legacy} onDone={clearLegacy} />;
  else if (!session) body = <RequestScreen onCreated={startSession} />;
  else if (lost) body = <Terminal title="Course introuvable" text="Cette course n’est plus accessible depuis cet appareil." onNew={clearSession} />;
  else if (!status) body = <p className="glass-panel p-8 text-center text-sm text-muted-foreground">Chargement de votre course…</p>;
  else body = <RideScreen session={session} status={status} onRefresh={poll} onNew={clearSession} />;

  return (
    <main className="relative min-h-svh overflow-hidden bg-background px-4 py-5 text-foreground sm:px-6 sm:py-8">
      <div className="taxi-grid pointer-events-none absolute inset-0" />
      <div className="relative mx-auto w-full max-w-3xl">
        <header className="grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-3">
          <Button asChild variant="ghost" size="icon" className="border border-border bg-secondary">
            <Link to="/" aria-label="Retour à l’accueil"><ArrowLeft /></Link>
          </Button>
          <div className="min-w-0 text-center">
            <p className="truncate text-sm font-semibold">Allo Taxi<span className="text-primary">..?</span></p>
            <p className="text-[10px] uppercase text-muted-foreground">Course express</p>
          </div>
          <span className="flex items-center gap-1.5 text-[10px] font-semibold uppercase text-live"><span className="size-2 rounded-full bg-live" />Libreville</span>
        </header>
        <div className="mt-7 animate-journey-in">{body}</div>
      </div>
    </main>
  );
}

/* ---------- Formulaire V1 ---------- */
function RequestScreen({ onCreated }: { onCreated: (s: Session) => void }) {
  const [form, setForm] = useState<RideForm>(initialForm);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [gps, setGps] = useState<{ lat: number; lng: number } | null>(null);
  const [gpsState, setGpsState] = useState<"idle" | "loading" | "ok" | "unavailable">("idle");
  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);

  function update<K extends keyof RideForm>(key: K, value: RideForm[K]) {
    setForm((c) => ({ ...c, [key]: value }));
    setErrors((c) => ({ ...c, [key]: "" }));
  }

  async function locate() {
    setGpsState("loading");
    const pos = await getPosition();
    setGps(pos);
    setGpsState(pos ? "ok" : "unavailable");
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const parsed = formSchema.safeParse(form);
    if (!parsed.success) {
      const next: Record<string, string> = {};
      for (const issue of parsed.error.issues) next[String(issue.path[0])] = issue.message;
      setErrors(next);
      return;
    }
    setErrors({});
    setSubmitError(null);
    setSubmitting(true);
    const d = parsed.data;
    const { data, error } = await supabase.rpc("create_ride_public_v1", {
      _client_name: d.firstName,
      _client_phone: `+241${d.phone.replace(/\D/g, "")}`,
      _pickup_location: d.pickup,
      _pickup_landmark: d.landmark,
      _pickup_lat: (gps?.lat ?? null) as unknown as number,
      _pickup_lng: (gps?.lng ?? null) as unknown as number,
      _dropoff_location: d.destination,
      _dropoff_note: d.dropoffNote,
      _passenger_count: d.passengers,
      _wants_ac: d.wantsAc,
      _allow_sharing: d.shared,
      _payment_method: d.payment,
      _price: d.price,
    });
    setSubmitting(false);
    const row = data?.[0];
    if (error || !row) return setSubmitError(errorText(error?.message, "La demande n’a pas pu être publiée. Vérifiez vos informations."));
    onCreated({ id: row.ride_id, token: row.token });
  }

  return (
    <section>
      <div className="mb-7 text-center">
        <p className="text-xs font-semibold uppercase text-primary">Sans inscription</p>
        <h1 className="mt-2 text-3xl font-semibold sm:text-4xl">Où allons-nous ?</h1>
        <p className="mt-2 text-sm text-muted-foreground">Publiez votre trajet en moins d’une minute.</p>
      </div>
      <form onSubmit={submit} className="space-y-5" noValidate>
        <section className="glass-panel grid gap-4 p-5 sm:grid-cols-2">
          <p className="flex items-center gap-2 text-sm font-semibold sm:col-span-2"><UserRound className="size-4 text-primary" />Vous</p>
          <Field label="Prénom" error={errors["firstName"]}><Input value={form.firstName} onChange={(e) => update("firstName", e.target.value)} maxLength={40} placeholder="Votre prénom" autoComplete="given-name" className="h-12" /></Field>
          <Field label="Numéro de téléphone" error={errors["phone"]}>
            <div className="grid grid-cols-[auto_minmax(0,1fr)]"><span className="flex h-12 items-center rounded-l-md border border-r-0 border-input bg-secondary px-3 text-sm font-semibold">+241</span><Input value={form.phone} onChange={(e) => update("phone", e.target.value)} maxLength={14} type="tel" inputMode="tel" placeholder="06 00 00 00" autoComplete="tel" className="h-12 rounded-l-none" /></div>
          </Field>
        </section>

        <section className="glass-panel space-y-4 p-5">
          <Field label="📍 Point de départ" error={errors["pickup"]}><Input value={form.pickup} onChange={(e) => update("pickup", e.target.value)} maxLength={120} placeholder="Ex : Charbonnages, entrée SNI" className="h-12" /></Field>
          <div className="flex flex-wrap items-center gap-3">
            <Button type="button" variant="outline" size="sm" onClick={() => void locate()} disabled={gpsState === "loading"}><Crosshair />{gpsState === "loading" ? "Localisation…" : "Ajouter ma position GPS"}</Button>
            <span className={cn("text-xs", gpsState === "ok" ? "text-live" : "text-muted-foreground")}>
              {gpsState === "ok" ? "Position GPS ajoutée" : gpsState === "unavailable" ? "Position indisponible — votre adresse suffit" : "Facultatif, aide les chauffeurs proches"}
            </span>
          </div>
          <Field label="Repère (facultatif)" error={errors["landmark"]}><Input value={form.landmark} onChange={(e) => update("landmark", e.target.value)} maxLength={120} placeholder="Ex : devant la pharmacie" className="h-12" /></Field>
          <div className="ml-5 h-5 border-l border-dashed border-primary/50" />
          <Field label="🏁 Destination" error={errors["destination"]}><Input value={form.destination} onChange={(e) => update("destination", e.target.value)} maxLength={120} placeholder="Ex : Nzeng-Ayong, rond-point" className="h-12" /></Field>
          <Field label="Indication complémentaire (facultatif)" error={errors["dropoffNote"]}><Input value={form.dropoffNote} onChange={(e) => update("dropoffNote", e.target.value)} maxLength={160} placeholder="Ex : portail bleu après l’école" className="h-12" /></Field>
        </section>

        <section className="glass-panel p-5">
          <p className="flex items-center gap-2 text-sm font-semibold"><Users className="size-4 text-primary" />Nombre de passagers</p>
          <div className="mt-3 grid grid-cols-4 gap-2 sm:grid-cols-8" role="radiogroup" aria-label="Nombre de passagers">
            {[1, 2, 3, 4, 5, 6, 7, 8].map((n) => (
              <Button key={n} type="button" role="radio" aria-checked={form.passengers === n} variant="outline" onClick={() => update("passengers", n)} className={cn("h-11", form.passengers === n && "border-primary bg-primary/10 text-primary hover:bg-primary/10 hover:text-primary")}>{n}</Button>
            ))}
          </div>
          {errors["passengers"] && <p className="mt-2 text-xs text-destructive" role="alert">{errors["passengers"]}</p>}
        </section>

        <section className="glass-panel p-5">
          <p className="text-sm font-semibold">Climatisation souhaitée</p>
          <div className="mt-3 grid grid-cols-2 gap-3">
            <ChoiceButton active={!form.wantsAc} onClick={() => update("wantsAc", false)} icon={<Wind />} title="Non" subtitle="Standard, ventilation" />
            <ChoiceButton active={form.wantsAc} onClick={() => update("wantsAc", true)} icon={<Snowflake />} title="Oui" subtitle="Véhicule climatisé" />
          </div>
        </section>

        <label className="glass-panel flex cursor-pointer items-start gap-3 p-5">
          <input type="checkbox" checked={form.shared} onChange={(e) => update("shared", e.target.checked)} className="mt-1 size-5 shrink-0 accent-[var(--color-primary)]" />
          <span>
            <span className="block text-sm font-semibold">J’accepte un trajet partagé</span>
            <span className="mt-1 block text-xs leading-5 text-muted-foreground">Votre préférence est transmise au chauffeur. Le partage de trajet n’est pas encore proposé : votre course reste individuelle.</span>
          </span>
        </label>

        <section className="glass-panel p-5">
          <p className="text-sm font-semibold">Mode de paiement</p>
          <div className="mt-3 grid grid-cols-3 gap-2">
            {(Object.keys(paymentLabels) as Payment[]).map((p) => (
              <Button key={p} type="button" variant="outline" aria-pressed={form.payment === p} onClick={() => update("payment", p)} className={cn("h-11 min-w-0 px-2 text-[11px]", form.payment === p && "border-primary bg-primary/10 text-primary hover:bg-primary/10 hover:text-primary")}>
                <span className="truncate">{paymentLabels[p]}</span>
              </Button>
            ))}
          </div>
          <p className="mt-3 text-xs text-muted-foreground">Vous réglez la course directement au chauffeur. Allo Taxi n’encaisse pas le prix de la course.</p>
        </section>

        <section className="glass-panel p-5">
          <div className="grid gap-5 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center">
            <div>
              <p className="flex items-center gap-2 text-sm font-semibold"><CircleDollarSign className="size-4 text-primary" />Votre prix proposé</p>
              <p className="mt-1 text-xs text-muted-foreground">C’est une proposition : le chauffeur peut l’accepter ou en discuter avec vous.</p>
            </div>
            <div className="grid grid-cols-[44px_minmax(0,1fr)_44px] items-center gap-2">
              <Button type="button" variant="outline" size="icon" aria-label="Réduire de 100 FCFA" onClick={() => update("price", Math.max(500, form.price - 100))}><Minus /></Button>
              <div className="relative"><Input aria-label="Prix proposé en FCFA" value={form.price} onChange={(e) => update("price", Number(e.target.value))} type="number" min={500} max={100000} step={100} className="h-11 min-w-0 pr-14 text-center font-bold tabular-nums" /><span className="pointer-events-none absolute right-2 top-3 text-[10px] font-semibold text-muted-foreground">FCFA</span></div>
              <Button type="button" variant="outline" size="icon" aria-label="Augmenter de 100 FCFA" onClick={() => update("price", Math.min(100000, form.price + 100))}><Plus /></Button>
            </div>
          </div>
          {errors["price"] && <p className="mt-2 text-xs text-destructive">{errors["price"]}</p>}
        </section>

        {submitError && <p className="rounded-md border border-destructive/30 bg-destructive/10 px-4 py-3 text-xs text-destructive" role="alert">{submitError}</p>}
        <Button type="submit" disabled={submitting} className="h-14 w-full text-base font-semibold shadow-gold">{submitting ? "Publication en cours…" : "Diffuser ma demande"} <Navigation /></Button>
      </form>
    </section>
  );
}

/* ---------- Suivi de course V1 ---------- */
function RideScreen({ session, status, onRefresh, onNew }: { session: Session; status: RideStatus; onRefresh: () => Promise<void>; onNew: () => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [confirmCancel, setConfirmCancel] = useState(false);
  const s = status.status;

  async function run(fn: () => PromiseLike<{ error: { message: string } | null }>, fallback: string) {
    setBusy(true);
    setError(null);
    const { error: err } = await fn();
    setBusy(false);
    if (err) setError(errorText(err.message, fallback));
    await onRefresh();
  }
  const cancel = () => run(() => supabase.rpc("cancel_ride_v1", { _ride_id: session.id, _token: session.token }), "Annulation impossible pour le moment.");

  if (TERMINAL.includes(s)) {
    const texts: Partial<Record<V1Status, string>> = {
      COMPLETED: "Merci d’avoir voyagé avec Allo Taxi.",
      CANCELED_BY_CLIENT: "Votre demande a été annulée.",
      CANCELED_BY_DRIVER: "Le chauffeur a dû annuler la course. Vous pouvez publier une nouvelle demande.",
      CONTACT_FAILED: "Aucun accord n’a été trouvé avec le chauffeur.",
      EXPIRED: "Aucun chauffeur n’a pris votre demande à temps. Vous pouvez la republier.",
      INCIDENT: "Un incident a été signalé sur cette course. Allo Taxi pourra vous recontacter.",
    };
    return <Terminal title={statusLabels[s]} text={texts[s] ?? ""} onNew={onNew} positive={s === "COMPLETED"} />;
  }

  return (
    <section className="space-y-5">
      <div className="glass-panel p-5 text-center sm:p-8">
        <StatusRail status={s} />
        <p className="mt-6 text-xs font-semibold uppercase text-live">{statusLabels[s]}</p>
        {s === "PENDING" && (
          <>
            <div className="mx-auto my-5 grid size-40 place-items-center">
              <div className="radar relative grid size-32 place-items-center rounded-full border border-live/30"><CarFront className="relative z-10 size-7 text-live" /></div>
            </div>
            <h1 className="text-2xl font-semibold">Les chauffeurs à proximité étudient votre demande.</h1>
            <p className="mt-2 text-sm text-muted-foreground">Gardez cet écran ouvert : il change dès qu’un chauffeur se propose.</p>
          </>
        )}
        {s === "CONTACT_PENDING" && status.contact && <ContactStep session={session} status={status} busy={busy} onRun={run} />}
        {s !== "PENDING" && s !== "CONTACT_PENDING" && (
          <h1 className="mt-2 text-2xl font-semibold">
            {s === "CONFIRMED" ? "Votre chauffeur va partir vers vous." : s === "DRIVER_EN_ROUTE" ? "Votre chauffeur arrive." : s === "DRIVER_ARRIVED" ? "Votre chauffeur vous attend au point de départ." : `En route vers ${status.dropoff_location}.`}
          </h1>
        )}
      </div>

      {status.safety && <SafetyCard safety={status.safety} />}
      <RideSummary status={status} />

      {error && <p className="rounded-md border border-destructive/30 bg-destructive/10 px-4 py-3 text-xs text-destructive" role="alert">{error}</p>}

      {CLIENT_CANCELABLE.includes(s) && (confirmCancel ? (
        <div className="glass-panel p-4 text-center">
          <p className="text-sm">Annuler vraiment votre demande ?</p>
          <div className="mt-3 grid grid-cols-2 gap-2">
            <Button type="button" variant="ghost" onClick={() => setConfirmCancel(false)}>Non, garder</Button>
            <Button type="button" variant="destructive" disabled={busy} onClick={() => void cancel()}>Oui, annuler</Button>
          </div>
        </div>
      ) : (
        <Button type="button" variant="outline" onClick={() => setConfirmCancel(true)} className="h-12 w-full"><X />Annuler ma demande</Button>
      ))}
      <p className="flex items-center justify-center gap-2 text-[10px] text-muted-foreground"><ShieldCheck className="size-3.5 text-live" />Votre numéro n’est jamais montré au chauffeur par Allo Taxi.</p>
    </section>
  );
}

function ContactStep({ session, status, busy, onRun }: { session: Session; status: RideStatus; busy: boolean; onRun: (fn: () => PromiseLike<{ error: { message: string } | null }>, fallback: string) => Promise<void> }) {
  const [mode, setMode] = useState<"choose" | "agree" | "disagree">("choose");
  const [finalPrice, setFinalPrice] = useState<number>(status.price_proposed);
  const contact = status.contact!;
  return (
    <div className="mt-2 text-left">
      <h1 className="text-center text-2xl font-semibold">Chauffeur trouvé : {contact.driver_first_name}</h1>
      <p className="mt-3 text-center text-sm text-muted-foreground">Échangez avec le chauffeur pour confirmer le prix et les modalités du trajet, puis revenez ici.</p>
      {contact.whatsapp_url ? (
        <Button asChild className="mt-5 h-14 w-full bg-live text-base font-semibold text-foreground shadow-live hover:bg-live/90">
          <a href={contact.whatsapp_url} target="_blank" rel="noreferrer"><MessageCircle />Contacter le chauffeur sur WhatsApp</a>
        </Button>
      ) : (
        <p className="mt-5 rounded-md border border-primary/30 bg-primary/10 p-3 text-center text-xs text-primary">Le numéro WhatsApp de ce chauffeur n’est pas disponible. Vous pouvez continuer à chercher un autre chauffeur ou annuler.</p>
      )}
      <p className="mt-2 text-center text-[11px] text-muted-foreground">WhatsApp s’ouvre avec un message prêt : c’est vous qui appuyez sur « Envoyer ». Allo Taxi n’envoie rien.</p>

      {mode === "choose" && (
        <div className="mt-6 grid gap-2 sm:grid-cols-2">
          <Button type="button" onClick={() => setMode("agree")} className="h-12 font-semibold shadow-gold">Nous sommes d’accord</Button>
          <Button type="button" variant="outline" onClick={() => setMode("disagree")} className="h-12">Nous n’avons pas trouvé d’accord</Button>
        </div>
      )}
      {mode === "agree" && (
        <div className="mt-6 rounded-md border border-border bg-background/35 p-4">
          <p className="text-xs text-muted-foreground">Prix proposé initial : <strong className="text-foreground">{status.price_proposed.toLocaleString("fr-FR")} FCFA</strong></p>
          <label className="mt-3 block"><span className="mb-2 block text-xs font-medium">Prix final convenu avec le chauffeur (FCFA)</span>
            <Input type="number" min={500} max={100000} step={100} value={finalPrice} onChange={(e) => setFinalPrice(Number(e.target.value))} className="h-12 text-center font-bold tabular-nums" />
          </label>
          <p className="mt-2 text-[11px] text-muted-foreground">Une fois confirmé, ce prix ne pourra plus être modifié.</p>
          <div className="mt-3 grid grid-cols-2 gap-2">
            <Button type="button" variant="ghost" onClick={() => setMode("choose")}>Retour</Button>
            <Button type="button" disabled={busy} onClick={() => void onRun(() => supabase.rpc("confirm_ride_after_contact_v1", { _ride_id: session.id, _token: session.token, _final_price: Math.round(finalPrice) }), "Confirmation impossible pour le moment.")} className="font-semibold">Confirmer {Number.isFinite(finalPrice) ? finalPrice.toLocaleString("fr-FR") : ""} FCFA</Button>
          </div>
        </div>
      )}
      {mode === "disagree" && (
        <div className="mt-6 space-y-3 rounded-md border border-border bg-background/35 p-4">
          <div>
            <p className="text-sm font-semibold">Continuer à chercher un autre chauffeur</p>
            <p className="mt-1 text-xs text-muted-foreground">Prévenez {contact.driver_first_name} sur WhatsApp : il libérera votre demande depuis son application, puis elle retournera automatiquement aux autres chauffeurs. Restez sur cet écran.</p>
          </div>
          <div className="border-t border-border pt-3">
            <p className="text-sm font-semibold">Arrêter ma recherche</p>
            <p className="mt-1 text-xs text-muted-foreground">La mise en relation se termine sans accord.</p>
            <Button type="button" variant="outline" disabled={busy} onClick={() => void onRun(() => supabase.rpc("mark_contact_failed_v1", { _ride_id: session.id, _token: session.token }), "Action impossible pour le moment.")} className="mt-2 w-full">Arrêter ma recherche</Button>
          </div>
          <Button type="button" variant="ghost" onClick={() => setMode("choose")} className="w-full text-xs">Retour</Button>
        </div>
      )}
    </div>
  );
}

function SafetyCard({ safety }: { safety: NonNullable<RideStatus["safety"]> }) {
  const vehicle = [safety.vehicle_make, safety.vehicle_model].filter(Boolean).join(" ") || "Véhicule";
  return (
    <article className="glass-panel p-5">
      <p className="flex items-center gap-2 text-xs font-semibold uppercase text-live"><BadgeCheck className="size-4" />Fiche de votre chauffeur</p>
      <div className="mt-4 grid grid-cols-[88px_minmax(0,1fr)] gap-4">
        {safety.driver_photo_url ? (
          <img src={safety.driver_photo_url} alt={`Photo de ${safety.driver_first_name}`} loading="lazy" className="size-[88px] rounded-md bg-[#0D0D0D] object-contain" />
        ) : (
          <div className="grid size-[88px] place-items-center rounded-md border border-dashed border-border bg-secondary p-2 text-center text-[10px] text-muted-foreground">Photo non encore disponible</div>
        )}
        <div className="min-w-0">
          <h2 className="truncate text-xl font-semibold">{safety.driver_first_name}</h2>
          <p className="mt-1 text-xs text-muted-foreground">{vehicle}{safety.vehicle_color ? ` · ${safety.vehicle_color}` : ""}</p>
          <p className="mt-3 text-[10px] font-semibold uppercase text-muted-foreground">Plaque</p>
          <p className="mt-1 text-xl font-bold">{safety.vehicle_plate ?? "Non renseignée"}</p>
        </div>
      </div>
      {!safety.vehicle_photo_url && <p className="mt-3 text-[11px] text-muted-foreground">Photo du véhicule : non encore disponible. Vérifiez la plaque avant de monter.</p>}
    </article>
  );
}

function RideSummary({ status }: { status: RideStatus }) {
  return (
    <div className="glass-panel p-5 text-left">
      <div className="grid grid-cols-[20px_minmax(0,1fr)] gap-x-3 gap-y-3 text-sm">
        <span aria-hidden="true">📍</span><p className="min-w-0 break-words"><span className="block text-[10px] uppercase text-muted-foreground">Départ</span>{status.pickup_location}{status.pickup_landmark && <span className="block text-xs text-muted-foreground">Repère : {status.pickup_landmark}</span>}</p>
        <span aria-hidden="true">🏁</span><p className="min-w-0 break-words"><span className="block text-[10px] uppercase text-muted-foreground">Destination</span>{status.dropoff_location}{status.dropoff_note && <span className="block text-xs text-muted-foreground">{status.dropoff_note}</span>}</p>
      </div>
      <dl className="mt-4 grid grid-cols-2 gap-3 border-t border-border pt-4 text-xs sm:grid-cols-3">
        {status.price_final != null
          ? <Fact label="Prix convenu" value={`${status.price_final.toLocaleString("fr-FR")} FCFA`} strong />
          : <Fact label="Prix proposé" value={`${status.price_proposed.toLocaleString("fr-FR")} FCFA`} />}
        <Fact label="Paiement au chauffeur" value={status.payment_method ? paymentLabels[status.payment_method] : "—"} />
        <Fact label="Passagers" value={String(status.passenger_count)} />
        <Fact label="Climatisation" value={status.wants_ac ? "Souhaitée" : "Non"} />
        <Fact label="Trajet partagé" value={status.allow_sharing ? "Accepté" : "Non"} />
      </dl>
    </div>
  );
}

function Fact({ label, value, strong = false }: { label: string; value: string; strong?: boolean }) {
  return <div className="min-w-0"><dt className="text-[10px] uppercase text-muted-foreground">{label}</dt><dd className={cn("mt-0.5 break-words", strong && "font-bold text-primary")}>{value}</dd></div>;
}

function StatusRail({ status }: { status: V1Status }) {
  const steps: { key: V1Status[]; icon: React.ReactNode; label: string }[] = [
    { key: ["PENDING"], icon: <Clock3 />, label: "Recherche" },
    { key: ["CONTACT_PENDING"], icon: <MessageCircle />, label: "Contact" },
    { key: ["CONFIRMED", "DRIVER_EN_ROUTE", "DRIVER_ARRIVED"], icon: <CarFront />, label: "Prise en charge" },
    { key: ["ONBOARD"], icon: <Flag />, label: "Trajet" },
  ];
  const current = steps.findIndex((st) => st.key.includes(status));
  return (
    <ol className="mx-auto flex max-w-sm items-center" aria-label={`Étape ${current + 1} sur 4`}>
      {steps.map((st, i) => (
        <li key={st.label} className={cn("flex items-center", i < steps.length - 1 && "flex-1")}>
          <span title={st.label} className={cn("grid size-8 shrink-0 place-items-center rounded-full border [&_svg]:size-3.5", i <= current ? "border-primary bg-primary text-primary-foreground" : "border-border bg-secondary text-muted-foreground")}>{st.icon}</span>
          {i < steps.length - 1 && <span className={cn("h-px flex-1", i < current ? "bg-primary" : "bg-border")} />}
        </li>
      ))}
    </ol>
  );
}

function Terminal({ title, text, onNew, positive = false }: { title: string; text: string; onNew: () => void; positive?: boolean }) {
  return (
    <section className="glass-panel p-8 text-center">
      <div className={cn("mx-auto grid size-14 place-items-center rounded-full", positive ? "bg-live/15 text-live" : "bg-secondary text-muted-foreground")}>{positive ? <BadgeCheck className="size-7" /> : <X className="size-7" />}</div>
      <h1 className="mt-5 text-2xl font-semibold">{title}</h1>
      {text && <p className="mt-2 text-sm text-muted-foreground">{text}</p>}
      <Button type="button" onClick={onNew} className="mt-6 h-12 w-full font-semibold shadow-gold sm:w-auto sm:px-8">Nouvelle demande</Button>
    </section>
  );
}

/* ---------- Compatibilité : course legacy publiée avant la mise à jour ---------- */
type LegacyRow = { status: string; chauffeur_first_name: string | null; vehicle_model: string | null; vehicle_plate: string | null; chauffeur_phone: string | null };
function LegacyTracker({ session, onDone }: { session: Session; onDone: () => void }) {
  const [row, setRow] = useState<LegacyRow | null | undefined>(undefined);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    const load = () => supabase.rpc("get_ride_status", { _ride_id: session.id, _token: session.token }).then(({ data, error: err }) => {
      if (!err) setRow((data?.[0] as LegacyRow | undefined) ?? null);
    });
    void load();
    const t = window.setInterval(load, POLL_MS);
    return () => window.clearInterval(t);
  }, [session]);
  async function cancel() {
    const { error: err } = await supabase.rpc("cancel_ride_public", { _ride_id: session.id, _token: session.token });
    if (err) return setError("Annulation impossible pour le moment.");
    onDone();
  }
  if (row === undefined) return <p className="glass-panel p-8 text-center text-sm text-muted-foreground">Chargement de votre course…</p>;
  if (!row || ["completed", "canceled"].includes(row.status)) {
    return <Terminal title={row?.status === "completed" ? "Course terminée" : "Course terminée ou expirée"} text="Votre ancienne demande n’est plus active." onNew={onDone} positive={row?.status === "completed"} />;
  }
  const labels: Record<string, string> = { pending: "Recherche d’un chauffeur", negotiating: "Mise en relation", onboard: "Course en cours" };
  return (
    <section className="glass-panel p-6 text-center">
      <p className="text-xs font-semibold uppercase text-primary">Demande publiée avant la mise à jour</p>
      <h1 className="mt-2 text-2xl font-semibold">{labels[row.status] ?? "Course en cours"}</h1>
      {row.chauffeur_first_name && <p className="mt-3 text-sm">{row.chauffeur_first_name} · {row.vehicle_model} · <strong>{row.vehicle_plate}</strong></p>}
      {row.chauffeur_phone && row.status === "negotiating" && (
        <Button asChild className="mt-5 h-12 w-full bg-live font-semibold text-foreground hover:bg-live/90"><a href={`https://wa.me/${row.chauffeur_phone.replace(/\D/g, "")}`} target="_blank" rel="noreferrer"><MessageCircle />Contacter le chauffeur sur WhatsApp</a></Button>
      )}
      {error && <p className="mt-3 text-xs text-destructive">{error}</p>}
      {row.status !== "onboard" && <Button type="button" variant="outline" onClick={() => void cancel()} className="mt-4 w-full"><X />Annuler ma demande</Button>}
    </section>
  );
}

/* ---------- Petits composants ---------- */
function ChoiceButton({ active, onClick, icon, title, subtitle }: { active: boolean; onClick: () => void; icon: React.ReactNode; title: string; subtitle: string }) {
  return (
    <Button type="button" variant="outline" aria-pressed={active} onClick={onClick} className={cn("h-20 min-w-0 justify-start px-3 text-left", active && "border-primary bg-primary/10 hover:bg-primary/10")}>
      <span className={cn("grid size-9 shrink-0 place-items-center rounded-md bg-secondary text-muted-foreground [&_svg]:size-4", active && "bg-primary text-primary-foreground")}>{icon}</span>
      <span className="min-w-0"><span className="block truncate text-xs font-semibold">{title}</span><span className="block truncate text-[10px] font-normal text-muted-foreground">{subtitle}</span></span>
    </Button>
  );
}

function Field({ label, error, children }: { label: string; error: string | undefined; children: React.ReactNode }) {
  return <label className="block"><span className="mb-2 block text-xs font-medium">{label}</span>{children}{error && <span className="mt-1.5 block text-xs text-destructive" role="alert">{error}</span>}</label>;
}
