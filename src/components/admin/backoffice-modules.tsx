import { AlertTriangle, Ban, CarFront, Clock3, Database, Gavel, Loader2, Power, Radio, RotateCcw, Save, Settings2, ShieldCheck, Trash2, Users } from "lucide-react";
import { useCallback, useEffect, useState, type FormEvent, type ReactNode } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { supabase } from "@/integrations/supabase/client";
import { cn } from "@/lib/utils";
import { useServerFn } from "@tanstack/react-start";
import { getXfinChecklist, type XfinChecklist } from "@/lib/xfin.functions";

type Notice = (message: string) => void;

export type SystemSettings = { dailyPrice: number; radiusKm: number; timeoutMin: number };
export const defaultSettings: SystemSettings = { dailyPrice: 1000, radiusKm: 5, timeoutMin: 15 };

export async function fetchSystemSettings(): Promise<SystemSettings> {
  const { data } = await supabase.from("system_settings").select("key, value");
  const get = (k: string, d: number) => {
    const v = data?.find((r) => r.key === k)?.value;
    return v == null ? d : Number(v);
  };
  return { dailyPrice: get("daily_price", 1000), radiusKm: get("search_radius_km", 5), timeoutMin: get("negotiation_timeout_min", 15) };
}

function minutesSince(value: string | null) {
  return value ? Math.max(0, Math.floor((Date.now() - new Date(value).getTime()) / 60000)) : 0;
}

function Panel({ icon, title, subtitle, action, children }: { icon: ReactNode; title: string; subtitle?: string; action?: ReactNode; children: ReactNode }) {
  return (
    <section className="glass-panel mt-4 p-5 sm:p-7">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div><p className="flex items-center gap-2 text-sm font-semibold">{icon}{title}</p>{subtitle && <p className="mt-1 text-xs text-muted-foreground">{subtitle}</p>}</div>
        {action}
      </div>
      <div className="mt-5">{children}</div>
    </section>
  );
}

function Chip({ tone, children }: { tone: "live" | "gold" | "danger" | "muted"; children: ReactNode }) {
  const tones = { live: "border-live/30 bg-live/10 text-live", gold: "border-primary/30 bg-primary/10 text-primary", danger: "border-destructive/30 bg-destructive/10 text-destructive", muted: "border-border bg-secondary text-muted-foreground" };
  return <span className={cn("inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[10px] font-semibold uppercase", tones[tone])}>{children}</span>;
}

/* ---------------- Vue d'ensemble ---------------- */
export function OverviewStats() {
  const [s, setS] = useState({ drivers: 0, online: 0, pendingDrivers: 0, pendingRides: 0, negotiating: 0, completedToday: 0 });
  useEffect(() => {
    const since = new Date(); since.setHours(0, 0, 0, 0);
    // Compteurs de courses : projection serveur workflow-aware (legacy + V1), plus de lecture directe de la table des courses
    void Promise.all([
      supabase.from("drivers").select("user_id", { count: "exact", head: true }).eq("status", "approved"),
      supabase.from("drivers").select("user_id", { count: "exact", head: true }).eq("status", "approved").eq("is_online", true).eq("is_active", true),
      supabase.from("drivers").select("user_id", { count: "exact", head: true }).eq("status", "pending"),
      supabase.rpc("admin_list_live_rides"),
      supabase.from("ride_logs").select("id", { count: "exact", head: true }).eq("resolution_status", "completed").gte("resolved_at", since.toISOString()),
    ]).then(([a, b, c, live, f]) => {
      const rows = ((live.data ?? []) as unknown as LiveRide[]);
      setS({ drivers: a.count ?? 0, online: b.count ?? 0, pendingDrivers: c.count ?? 0, pendingRides: rows.filter((r) => phaseOf(r) === "waiting").length, negotiating: rows.filter((r) => phaseOf(r) === "contact").length, completedToday: f.count ?? 0 });
    });
  }, []);
  const items = [
    { label: "Chauffeurs validés", value: s.drivers, icon: <CarFront className="size-4" /> },
    { label: "En ligne maintenant", value: s.online, icon: <Radio className="size-4 text-live" /> },
    { label: "Dossiers à valider", value: s.pendingDrivers, icon: <ShieldCheck className="size-4" /> },
    { label: "Courses en attente", value: s.pendingRides, icon: <Clock3 className="size-4" /> },
    { label: "Mise en relation", value: s.negotiating, icon: <Users className="size-4" /> },
    { label: "Courses legacy terminées aujourd’hui", value: s.completedToday, icon: <ShieldCheck className="size-4 text-live" /> },
  ];
  return (
    <div className="mt-4 grid grid-cols-2 gap-3 sm:grid-cols-3">
      {items.map((it) => (
        <div key={it.label} className="glass-panel p-4"><p className="flex items-center gap-2 text-[10px] uppercase text-muted-foreground">{it.icon}{it.label}</p><p className="mt-2 text-2xl font-semibold tabular-nums">{it.value}</p></div>
      ))}
    </div>
  );
}

/* ---------------- Flotte ---------------- */
type DriverRow = { user_id: string; first_name: string; phone: string; vehicle_model: string; vehicle_plate: string; has_ac: boolean; status: string; is_online: boolean; is_active: boolean; last_seen_at: string | null; is_demo: boolean };

export function FleetManagement({ onNotice, maskPhone }: { onNotice: Notice; maskPhone: (p: string) => string }) {
  const [rows, setRows] = useState<DriverRow[]>([]);
  const [filter, setFilter] = useState<"all" | "pending" | "approved" | "suspended">("all");
  const load = useCallback(async () => {
    const { data } = await supabase.from("drivers").select("user_id, first_name, phone, vehicle_model, vehicle_plate, has_ac, status, is_online, is_active, last_seen_at, is_demo").is("deleted_at", null).order("created_at", { ascending: false });
    setRows(data ?? []);
  }, []);
  useEffect(() => { void load(); }, [load]);

  async function decide(id: string, approve: boolean) {
    const { error } = await supabase.rpc("approve_driver", { _user_id: id, _approve: approve });
    if (error) return onNotice("Décision non enregistrée.");
    onNotice(approve ? "Dossier validé." : "Chauffeur suspendu (réversible).");
    void load();
  }
  async function toggleActive(row: DriverRow) {
    const { error } = await supabase.rpc("set_driver_active", { _user_id: row.user_id, _active: !row.is_active });
    if (error) return onNotice("Changement impossible.");
    onNotice(row.is_active ? "Compte désactivé." : "Compte réactivé.");
    void load();
  }

  const shown = rows.filter((r) => filter === "all" || r.status === filter);
  const labels = { all: "Tous", pending: "À valider", approved: "Validés", suspended: "Suspendus" } as const;
  return (
    <Panel icon={<CarFront className="size-4 text-primary" />} title="Flotte de chauffeurs" subtitle={`${rows.length} chauffeurs enregistrés · ${rows.filter((r) => r.is_online && r.is_active && r.status === "approved").length} en ligne`}
      action={<div className="flex flex-wrap gap-1">{(Object.keys(labels) as (keyof typeof labels)[]).map((k) => <Button key={k} size="sm" variant={filter === k ? "default" : "outline"} onClick={() => setFilter(k)} className="h-8 text-[11px]">{labels[k]}</Button>)}</div>}>
      <div className="space-y-2">
        {shown.length === 0 && <p className="text-xs text-muted-foreground">Aucun chauffeur dans cette catégorie.</p>}
        {shown.map((r) => (
          <div key={r.user_id} className={cn("grid gap-3 rounded-md border border-border bg-secondary/60 p-4 md:grid-cols-[minmax(0,1fr)_auto] md:items-center", !r.is_active && "opacity-60")}>
            <div className="min-w-0">
              <div className="flex flex-wrap items-center gap-2">
                <p className="text-sm font-semibold">{r.first_name}</p>
                {r.status === "approved" && (r.is_online && r.is_active ? <Chip tone="live">● En ligne</Chip> : <Chip tone="muted">Hors ligne</Chip>)}
                {r.status === "pending" && <Chip tone="gold">Dossier en attente</Chip>}
                {r.status === "suspended" && <Chip tone="danger">Suspendu</Chip>}
                {!r.is_active && <Chip tone="danger">Désactivé</Chip>}
                {r.is_demo && <Chip tone="muted">Démo</Chip>}
              </div>
              <p className="mt-1 text-xs text-muted-foreground">{r.vehicle_model} · <strong className="uppercase text-primary">{r.vehicle_plate}</strong> · {r.has_ac ? "Climatisé" : "Standard"} · {maskPhone(r.phone)}</p>
            </div>
            <div className="flex flex-wrap gap-2">
              {r.status !== "approved" && <Button size="sm" onClick={() => void decide(r.user_id, true)} className="bg-live text-foreground hover:bg-live/90">{r.status === "pending" ? "Valider" : "Lever la suspension"}</Button>}
              {r.status === "pending" && <Button size="sm" variant="outline" onClick={() => void decide(r.user_id, false)} className="text-destructive">Rejeter</Button>}
              {r.status === "approved" && <Button size="sm" variant="outline" onClick={() => void decide(r.user_id, false)} className="text-destructive"><Ban className="size-3.5" />Suspendre</Button>}
              <Button size="sm" variant="ghost" onClick={() => void toggleActive(r)}><Power className="size-3.5" />{r.is_active ? "Désactiver" : "Réactiver"}</Button>
            </div>
          </div>
        ))}
      </div>
    </Panel>
  );
}

/* ---------------- Dispatch en direct ---------------- */
type LiveRide = { id: string; workflow_version: "legacy" | "v1"; is_demo: boolean; status: string; client_name: string; pickup_location: string; dropoff_location: string; price_proposed: number; price_final: number | null; payment_method: string; wants_ac: boolean; passenger_count: number | null; driver_label: string | null; since: string | null; created_at: string };
type Phase = "waiting" | "contact" | "running";
function phaseOf(r: LiveRide): Phase {
  if (r.workflow_version === "legacy") return r.status === "pending" ? "waiting" : r.status === "negotiating" ? "contact" : "running";
  return r.status === "PENDING" ? "waiting" : r.status === "CONTACT_PENDING" ? "contact" : "running";
}
const v1StatusLabels: Record<string, string> = { CONFIRMED: "Confirmée", DRIVER_EN_ROUTE: "Chauffeur en route", DRIVER_ARRIVED: "Chauffeur arrivé", ONBOARD: "À bord", onboard: "À bord" };

export function LiveDispatch({ timeoutMin }: { timeoutMin: number }) {
  const [rides, setRides] = useState<LiveRide[]>([]);
  const [, tick] = useState(0);
  const load = useCallback(async () => {
    const { data } = await supabase.rpc("admin_list_live_rides");
    setRides((data ?? []) as unknown as LiveRide[]);
  }, []);
  useEffect(() => {
    void load();
    const refresh = window.setInterval(() => void load(), 15000);
    const clock = window.setInterval(() => tick((n) => n + 1), 30000);
    return () => { window.clearInterval(refresh); window.clearInterval(clock); };
  }, [load]);

  const pending = rides.filter((r) => phaseOf(r) === "waiting");
  const nego = rides.filter((r) => phaseOf(r) === "contact");
  const running = rides.filter((r) => phaseOf(r) === "running");
  // Le délai de négociation avec pénalité ne s'applique qu'aux courses legacy
  const isOverdue = (r: LiveRide) => r.workflow_version === "legacy" && r.status === "negotiating" && minutesSince(r.since) >= timeoutMin;
  const late = nego.filter(isOverdue);

  const card = (r: LiveRide) => {
    const mins = minutesSince(r.since);
    const overdue = isOverdue(r);
    const phase = phaseOf(r);
    return (
      <div key={r.id} className={cn("rounded-md border bg-secondary/60 p-3", overdue ? "border-destructive/50" : "border-border")}>
        <div className="flex items-center justify-between gap-2"><p className="truncate text-xs font-semibold">{r.pickup_location} → {r.dropoff_location}</p><span className="shrink-0 text-sm font-bold tabular-nums text-primary">{(r.price_final ?? r.price_proposed).toLocaleString("fr-FR")} F</span></div>
        <p className="mt-1 text-[11px] text-muted-foreground">
          <Chip tone={r.workflow_version === "v1" ? "live" : "muted"}>{r.workflow_version === "v1" ? "V1" : "Legacy"}</Chip>{r.is_demo && <> <Chip tone="muted">Démo</Chip></>}{" "}
          {r.client_name} · {r.payment_method}{r.passenger_count ? ` · ${r.passenger_count} pass.` : ""}{r.wants_ac ? " · ❄️" : ""}{r.price_final != null ? " · prix convenu" : ""}
        </p>
        {r.driver_label && <p className="mt-1 text-[11px] text-foreground">Chauffeur : {r.driver_label}</p>}
        <p className={cn("mt-2 flex items-center gap-1 text-[10px] font-semibold uppercase", overdue ? "text-destructive" : "text-muted-foreground")}><Clock3 className="size-3" />{mins} min {phase === "waiting" ? "d’attente" : phase === "contact" ? "de mise en relation" : `· ${v1StatusLabels[r.status] ?? r.status}`}{overdue && " — délai dépassé"}</p>
      </div>
    );
  };

  return (
    <Panel icon={<Radio className="size-4 text-live" />} title="Supervision · Dispatch en direct" subtitle={`Actualisation automatique · Délai de négociation legacy : ${timeoutMin} min`} action={<Button size="sm" variant="outline" onClick={() => void load()}><RotateCcw className="size-3.5" />Actualiser</Button>}>
      {late.length > 0 && <div className="mb-4 flex items-center gap-2 rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-xs text-destructive" role="alert"><AlertTriangle className="size-4" />{late.length} négociation{late.length > 1 ? "s" : ""} legacy au-delà du délai autorisé — elles seront remises dans le pool avec pénalité.</div>}
      <div className="grid gap-4 md:grid-cols-3">
        <div><p className="mb-2 text-[10px] font-semibold uppercase text-muted-foreground">En attente de chauffeur ({pending.length})</p><div className="space-y-2">{pending.length ? pending.map(card) : <p className="text-xs text-muted-foreground">Aucune demande en attente.</p>}</div></div>
        <div><p className="mb-2 text-[10px] font-semibold uppercase text-muted-foreground">Mise en relation ({nego.length})</p><div className="space-y-2">{nego.length ? nego.map(card) : <p className="text-xs text-muted-foreground">Aucune mise en relation.</p>}</div></div>
        <div><p className="mb-2 text-[10px] font-semibold uppercase text-muted-foreground">Courses en cours ({running.length})</p><div className="space-y-2">{running.length ? running.map(card) : <p className="text-xs text-muted-foreground">Aucune course en cours.</p>}</div></div>
      </div>
    </Panel>
  );
}

/* ---------------- Litiges & sanctions ---------------- */
type Penalty = { id: string; driver_id: string; reason: string; is_active: boolean; created_at: string };

export function DisputesAndSanctions({ onNotice }: { onNotice: Notice }) {
  const [rows, setRows] = useState<Penalty[]>([]);
  const [names, setNames] = useState<Record<string, string>>({});
  const [suspended, setSuspended] = useState<{ user_id: string; first_name: string; vehicle_plate: string }[]>([]);
  const load = useCallback(async () => {
    const [{ data }, { data: drivers }] = await Promise.all([
      supabase.from("driver_penalties").select("id, driver_id, reason, is_active, created_at").is("deleted_at", null).order("created_at", { ascending: false }).limit(100),
      supabase.from("drivers").select("user_id, first_name, vehicle_plate, status"),
    ]);
    setRows(data ?? []);
    setNames(Object.fromEntries((drivers ?? []).map((d) => [d.user_id, `${d.first_name} (${d.vehicle_plate})`])));
    setSuspended((drivers ?? []).filter((d) => d.status === "suspended"));
  }, []);
  useEffect(() => { void load(); }, [load]);

  async function toggle(p: Penalty) {
    const { error } = await supabase.rpc("set_penalty_active", { _id: p.id, _active: !p.is_active });
    if (error) return onNotice("Changement impossible.");
    onNotice(p.is_active ? "Sanction levée." : "Sanction rétablie.");
    void load();
  }
  const counts = rows.filter((r) => r.is_active).reduce<Record<string, number>>((acc, r) => ({ ...acc, [r.driver_id]: (acc[r.driver_id] ?? 0) + 1 }), {});
  const repeat = Object.entries(counts).filter(([, n]) => n >= 2);

  return (
    <Panel icon={<Gavel className="size-4 text-primary" />} title="Litiges & sanctions" subtitle={`${rows.filter((r) => r.is_active).length} sanctions actives · ${suspended.length} chauffeur(s) suspendu(s)`}>
      {repeat.length > 0 && <div className="mb-4 rounded-md border border-primary/30 bg-primary/5 p-3 text-xs"><p className="font-semibold text-primary">Récidives à surveiller</p>{repeat.map(([id, n]) => <p key={id} className="mt-1 text-muted-foreground">{names[id] ?? "Chauffeur"} — {n} sanctions actives</p>)}</div>}
      {suspended.length > 0 && <div className="mb-4 flex flex-wrap gap-2">{suspended.map((d) => <Chip key={d.user_id} tone="danger">Suspendu · {d.first_name} {d.vehicle_plate}</Chip>)}</div>}
      <div className="space-y-2">
        {rows.length === 0 && <p className="text-xs text-muted-foreground">Aucun litige enregistré.</p>}
        {rows.map((p) => (
          <div key={p.id} className={cn("flex flex-col gap-2 rounded-md border border-border bg-secondary/60 p-3 sm:flex-row sm:items-center sm:justify-between", !p.is_active && "opacity-60")}>
            <div className="min-w-0"><p className="text-xs font-semibold">{names[p.driver_id] ?? "Chauffeur"}</p><p className="mt-0.5 text-[11px] text-muted-foreground">{p.reason} · {new Date(p.created_at).toLocaleString("fr-FR", { timeZone: "Africa/Libreville", dateStyle: "short", timeStyle: "short" })}</p></div>
            <Button size="sm" variant="ghost" onClick={() => void toggle(p)} className={p.is_active ? "text-live" : "text-destructive"}>{p.is_active ? "Lever la sanction" : "Rétablir"}</Button>
          </div>
        ))}
      </div>
    </Panel>
  );
}

/* ---------------- Paramètres système ---------------- */
export function SystemSettingsPanel({ settings, onSaved, onNotice }: { settings: SystemSettings; onSaved: (s: SystemSettings) => void; onNotice: Notice }) {
  const [form, setForm] = useState(settings);
  const [busy, setBusy] = useState(false);
  useEffect(() => setForm(settings), [settings]);
  async function save(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    const { error } = await supabase.rpc("update_system_settings", { _daily_price: Math.round(form.dailyPrice), _radius_km: form.radiusKm, _timeout_min: Math.round(form.timeoutMin) });
    setBusy(false);
    if (error) return onNotice("Valeurs refusées : vérifiez les limites.");
    onSaved(form);
    onNotice("Paramètres système enregistrés.");
  }
  const field = (label: string, hint: string, key: keyof SystemSettings, min: number, max: number, step: number) => (
    <label className="block"><span className="mb-1 block text-xs font-medium">{label}</span><Input type="number" min={min} max={max} step={step} value={form[key]} onChange={(e) => setForm({ ...form, [key]: Number(e.target.value) })} className="h-12 text-lg font-bold tabular-nums" /><span className="mt-1 block text-[10px] text-muted-foreground">{hint}</span></label>
  );
  return (
    <>
    <Panel icon={<Settings2 className="size-4 text-primary" />} title="Paramètres système" subtitle="Appliqués immédiatement aux chauffeurs et au dispatch.">
      <form onSubmit={save} className="grid gap-4 sm:grid-cols-3">
        {field("Forfait journalier (FCFA)", "Entre 100 et 100 000 FCFA", "dailyPrice", 100, 100000, 100)}
        {field("Rayon de recherche (km)", "Entre 0,5 et 50 km", "radiusKm", 0.5, 50, 0.5)}
        {field("Délai de négociation (min)", "Entre 1 et 240 minutes", "timeoutMin", 1, 240, 1)}
        <Button type="submit" disabled={busy} className="h-12 font-bold shadow-gold sm:col-span-3"><Save />Enregistrer les paramètres</Button>
      </form>
    </Panel>
    <TicketModePanel onNotice={onNotice} />
    <SharedRidesToggle onNotice={onNotice} />
    </>
  );
}

/* Ticket journalier V1 : lecture seule + changement via set_driver_ticket_mode (jamais direct) */
function TicketModePanel({ onNotice }: { onNotice: Notice }) {
  const [cfg, setCfg] = useState<{ mode: string; xfin_configured: boolean; standard_price_fcfa: number } | null>(null);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const load = () => void supabase.rpc("get_ticket_config").then(({ data }) => { if (data) setCfg(data as typeof cfg); });
  useEffect(load, []);
  async function change(mode: "FREE" | "PAID") {
    setBusy(true); setError(null);
    const { error: err } = await supabase.rpc("set_driver_ticket_mode", { _mode: mode, _reason: reason.trim() });
    setBusy(false);
    if (err) {
      setError(err.message.includes("XFIN_NOT_CONFIGURED") ? "Refusé : le paiement xFin n’est pas configuré. Le mode reste FREE." : err.message.includes("REASON") ? "Motif obligatoire (3 caractères minimum)." : "Changement refusé.");
    } else onNotice(`Mode ${mode} confirmé.`);
    load();
  }
  return (
    <Panel icon={<Settings2 className="size-4 text-primary" />} title="Ticket journalier chauffeur" subtitle="Un accès offert (FREE) n’est jamais une recette.">
      {!cfg ? <p className="text-xs text-muted-foreground">Chargement…</p> : (
        <div className="grid gap-3">
          <div className="flex flex-wrap gap-2">
            <Chip tone={cfg.mode === "FREE" ? "live" : "gold"}>Mode : {cfg.mode}</Chip>
            <Chip tone={cfg.xfin_configured ? "live" : "danger"}>xFin : {cfg.xfin_configured ? "CONFIGURÉ" : "NON CONFIGURÉ"}</Chip>
            <Chip tone="muted">Tarif standard : {cfg.standard_price_fcfa.toLocaleString("fr-FR")} FCFA</Chip>
          </div>
          <Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Motif du changement" className="h-11" />
          <div className="flex gap-2">
            <Button type="button" variant="secondary" disabled={busy || cfg.mode === "FREE"} onClick={() => void change("FREE")}>Passer en FREE</Button>
            <Button type="button" variant="secondary" disabled={busy || cfg.mode === "PAID"} onClick={() => void change("PAID")}>Passer en PAID</Button>
          </div>
          {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
          <XfinChecklistView />
        </div>
      )}
    </Panel>
  );
}

/* Checklist xFin non sensible (jamais de secret affiché) */
function XfinChecklistView() {
  const fetchChecklist = useServerFn(getXfinChecklist);
  const [c, setC] = useState<XfinChecklist | null>(null);
  useEffect(() => { void fetchChecklist().then(setC).catch(() => setC(null)); }, [fetchChecklist]);
  if (!c) return null;
  const ok = (v: string) => (["configurés", "configuré", "oui", "compatible"].includes(v) ? "live" : v === "inconnu" ? "muted" : "danger") as "live" | "muted" | "danger";
  return (
    <div className="flex flex-wrap gap-2 border-t border-border pt-3">
      <Chip tone={ok(c.credentials)}>Credentials : {c.credentials}</Chip>
      <Chip tone={ok(c.appActive)}>Application active : {c.appActive}</Chip>
      <Chip tone={ok(c.feeOwner)}>Fee owner : {c.feeOwner}</Chip>
      <Chip tone={ok(c.webhookSecret)}>Secret webhook : {c.webhookSecret}</Chip>
      {c.error && <Chip tone="danger">{c.error}</Chip>}
    </div>
  );
}

function SharedRidesToggle({ onNotice }: { onNotice: Notice }) {
  const [on, setOn] = useState<boolean | null>(null);
  useEffect(() => { void supabase.rpc("shared_rides_enabled").then(({ data }) => setOn(Boolean(data))); }, []);
  async function toggle() {
    const next = !on;
    const { error } = await supabase.rpc("set_shared_rides_enabled", { _on: next });
    if (error) return onNotice("Changement impossible.");
    setOn(next);
    onNotice(next ? "Verrouillage du trajet activé." : "Verrouillage du trajet désactivé.");
  }
  return (
    <Panel icon={<Users className="size-4 text-primary" />} title="Verrouillage du trajet (taxi partagé)" subtitle="Activé : le trajet du premier client verrouille le chauffeur — il ne peut prendre que des passagers ayant accepté le partage et allant dans la même direction (3 places, prix inchangé). Désactivé : le chauffeur reste libre de prendre toute course, même avec un passager à bord."
      action={on === null ? <Loader2 className="size-4 animate-spin" /> : <Chip tone={on ? "live" : "muted"}>{on ? "Activé" : "Désactivé"}</Chip>}>
      <Button onClick={() => void toggle()} disabled={on === null} variant={on ? "outline" : "default"} className="h-11 font-bold"><Power />{on ? "Désactiver le verrouillage du trajet" : "Activer le verrouillage du trajet"}</Button>
    </Panel>
  );
}

/* ---------------- Données de démo ---------------- */
export function DemoDataControls({ onNotice, onChanged }: { onNotice: Notice; onChanged: () => void }) {
  const [busy, setBusy] = useState<"load" | "reset" | null>(null);
  const [confirmReset, setConfirmReset] = useState(false);
  async function run(kind: "load" | "reset") {
    setBusy(kind);
    const { error } = await supabase.rpc(kind === "load" ? "load_demo_data" : "reset_demo_data");
    setBusy(null);
    setConfirmReset(false);
    if (error) return onNotice("Opération impossible.");
    onNotice(kind === "load" ? "Données de démo de Libreville chargées." : "Données de démo effacées.");
    onChanged();
  }
  return (
    <Panel icon={<Database className="size-4 text-primary" />} title="Données de démonstration" subtitle="8 chauffeurs, courses en direct, 24 courses clôturées, 6 mois d’abonnements. Les vraies données ne sont jamais touchées.">
      <div className="grid gap-2 sm:grid-cols-2">
        <Button onClick={() => void run("load")} disabled={busy !== null} className="h-11 font-bold shadow-gold">{busy === "load" ? <Loader2 className="animate-spin" /> : <Database />}Charger les données de démo</Button>
        {confirmReset ? (
          <Button variant="outline" onClick={() => void run("reset")} disabled={busy !== null} className="h-11 border-destructive text-destructive">{busy === "reset" ? <Loader2 className="animate-spin" /> : <Trash2 />}Confirmer l’effacement</Button>
        ) : (
          <Button variant="outline" onClick={() => setConfirmReset(true)} disabled={busy !== null} className="h-11 text-destructive"><Trash2 />Tout réinitialiser (démo)</Button>
        )}
      </div>
    </Panel>
  );
}
