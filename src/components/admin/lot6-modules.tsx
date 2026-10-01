import { useCallback, useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";

type Notice = (text: string) => void;
// Admin RPC payloads are server-shaped jsonb; fields are rendered defensively via s()/fcfa().
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Row = any;

const fcfa = (n: unknown) => `${Number(n ?? 0).toLocaleString("fr-FR")} FCFA`;
const dt = (v: unknown) => (v ? new Date(String(v)).toLocaleString("fr-FR", { dateStyle: "short", timeStyle: "short" }) : "—");
const s = (v: unknown) => (v === null || v === undefined || v === "" ? "—" : String(v));

function useRpc<T>(fn: () => PromiseLike<{ data: unknown; error: { message: string } | null }>) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const reload = useCallback(async () => {
    const { data, error } = await fn();
    if (error) setError(error.message);
    else { setError(null); setData(data as T); }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useEffect(() => { void reload(); }, [reload]);
  return { data, error, reload };
}

function Panel({ title, subtitle, children }: { title: string; subtitle?: string; children: React.ReactNode }) {
  return (
    <section className="mt-6 rounded-2xl border border-border bg-card/80 p-5 backdrop-blur">
      <h2 className="font-display text-lg font-semibold text-foreground">{title}</h2>
      {subtitle && <p className="mt-1 text-xs text-muted-foreground">{subtitle}</p>}
      <div className="mt-4">{children}</div>
    </section>
  );
}

function Stat({ label, value, accent }: { label: string; value: string; accent?: boolean }) {
  return (
    <div className="rounded-xl border border-border bg-background/40 p-4">
      <p className="text-[11px] uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className={cn("mt-1 text-2xl font-semibold text-foreground", accent && "text-primary")}>{value}</p>
    </div>
  );
}

const errMsg = (m: string) => {
  const map: Record<string, string> = {
    REASON_REQUIRED: "Le motif est obligatoire.",
    REFUSED: "Action réservée au Superadmin.",
    RESTRICTION_ALREADY_ACTIVE: "Cette restriction est déjà active.",
    PRICE_NOT_CONFIRMED: "Le prix final n’est pas encore confirmé.",
    PRICE_UNCHANGED: "Le nouveau prix est identique.",
    SHARE_RULES_CAP_EXCEEDED: "La somme des parts dépasserait 100 %.",
    SHARE_RULE_OVERLAP: "Cet associé a déjà une règle sur cette période.",
    SHARE_RULE_RETROACTIVE_START: "Une règle ne peut pas commencer dans le passé.",
  };
  const k = Object.keys(map).find((x) => m.includes(x));
  return (k && map[k]) || m;
};

/* 1. Dashboard V1 */
export function DashboardV1() {
  const { data, error } = useRpc<Row>(() => supabase.rpc("admin_dashboard_v1"));
  if (error) return <Panel title="Tableau de bord V1"><p className="text-sm text-destructive">{error}</p></Panel>;
  const d = data ?? {};
  return (
    <Panel title="Tableau de bord V1" subtitle="Courses V1, legacy et démo comptées séparément.">
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat label="Courses V1 actives" value={s(d.v1_active ?? 0)} accent />
        <Stat label="V1 terminées aujourd’hui" value={s(d.v1_completed_today ?? 0)} />
        <Stat label="Legacy (historique)" value={`${s(d.legacy_total ?? 0)} · ${s(d.legacy_active ?? 0)} actives`} />
        <Stat label="Courses démo" value={s(d.demo_total ?? 0)} />
        <Stat label="Chauffeurs en ligne" value={s(d.drivers_online ?? 0)} />
        <Stat label="Chauffeurs engagés" value={s(d.drivers_engaged ?? 0)} />
        <Stat label="Charge partagée" value={`${s(d.shared_rides ?? 0)} courses · ${s(d.shared_seats ?? 0)}/${s(d.shared_capacity ?? 0)} places`} />
        <Stat label="Capacité inconnue" value={s(d.capacity_unknown ?? 0)} />
      </div>
    </Panel>
  );
}

/* 2. Register + 5. price correction */
export function RidesRegisterV1({ onNotice }: { onNotice: Notice }) {
  const { data, error, reload } = useRpc<Row[]>(() => supabase.rpc("admin_list_rides_v1", { _limit: 200 }));
  const [editing, setEditing] = useState<string | null>(null);
  const [price, setPrice] = useState("");
  const [reason, setReason] = useState("");
  const submit = async (id: string) => {
    const { error } = await supabase.rpc("admin_correct_price_final_v1", { _ride: id, _new_price: Number(price), _reason: reason });
    if (error) { onNotice(errMsg(error.message)); return; }
    onNotice("Prix final corrigé et journalisé.");
    setEditing(null); setPrice(""); setReason(""); void reload();
  };
  return (
    <Panel title="Registre des courses" subtitle="Lecture contrôlée, sans jeton ni téléphone. Les courses legacy sont marquées.">
      {error && <p className="text-sm text-destructive">{error}</p>}
      <div className="overflow-x-auto">
        <table className="w-full min-w-[900px] text-left text-xs">
          <thead className="text-muted-foreground">
            <tr>{["Version", "État", "Client", "Chauffeur", "Véhicule", "Proposé", "Final", "Paiement", "Partage", "Créée", "Motif fin", ""].map((h) => <th key={h} className="px-2 py-2 font-medium">{h}</th>)}</tr>
          </thead>
          <tbody>
            {(data ?? []).map((r) => {
              const id = String(r.ride_id);
              const v1 = r.workflow_version === "v1";
              const canFix = v1 && r.price_final_confirmed_at && !r.is_demo;
              return (
                <tr key={id} className="border-t border-border align-top">
                  <td className="px-2 py-2">
                    <span className={cn("rounded-full px-2 py-0.5 text-[10px] font-semibold", v1 ? "bg-primary/15 text-primary" : "bg-muted text-muted-foreground")}>{r.is_demo ? "DÉMO" : v1 ? "V1" : "LEGACY"}</span>
                  </td>
                  <td className="px-2 py-2">{s(r.state)}</td>
                  <td className="px-2 py-2">{s(r.client_first_name)}</td>
                  <td className="px-2 py-2">{s(r.driver_name)}</td>
                  <td className="px-2 py-2">{s(r.vehicle_plate)}</td>
                  <td className="px-2 py-2">{fcfa(r.price_proposed)}</td>
                  <td className="px-2 py-2">{r.price_final == null ? "—" : fcfa(r.price_final)}</td>
                  <td className="px-2 py-2">{s(r.payment_method)}</td>
                  <td className="px-2 py-2">{r.allow_sharing ? "Oui" : "Non"}</td>
                  <td className="px-2 py-2">{dt(r.created_at)}</td>
                  <td className="px-2 py-2">{s(r.cancel_reason)}</td>
                  <td className="px-2 py-2">
                    {canFix && editing !== id && <Button size="sm" variant="outline" onClick={() => { setEditing(id); setPrice(String(r.price_final ?? "")); }}>Corriger le prix</Button>}
                    {editing === id && (
                      <div className="flex min-w-[220px] flex-col gap-2">
                        <Input type="number" value={price} onChange={(e) => setPrice(e.target.value)} aria-label="Nouveau prix final" />
                        <Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Motif obligatoire" aria-label="Motif" />
                        <div className="flex gap-2">
                          <Button size="sm" onClick={() => void submit(id)} disabled={!reason.trim() || !price}>Valider</Button>
                          <Button size="sm" variant="ghost" onClick={() => setEditing(null)}>Annuler</Button>
                        </div>
                      </div>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </Panel>
  );
}

/* 3. Finance truth + 4. associates */
export function FinanceV1({ onNotice }: { onNotice: Notice }) {
  const fin = useRpc<Row>(() => supabase.rpc("admin_finance_v1"));
  const sh = useRpc<Row>(() => supabase.rpc("admin_associate_shares_v1"));
  const [assoc, setAssoc] = useState("");
  const [pct, setPct] = useState("");
  const [from, setFrom] = useState("");
  const [closeDate, setCloseDate] = useState<Record<string, string>>({});
  const f = fin.data ?? {};
  const legacy = (f.legacy_simulation ?? {}) as Row;
  const txs = (f.transactions ?? []) as Row[];
  const associates = (sh.data?.associates ?? []) as Row[];
  const rules = (sh.data?.rules ?? []) as Row[];
  const shares = (sh.data?.shares ?? []) as Row[];

  const createRule = async () => {
    const { error } = await supabase.rpc("admin_create_associate_rule_v1", { _associate: assoc, _percent: Number(pct), _from: from });
    if (error) { onNotice(errMsg(error.message)); return; }
    onNotice("Règle de part créée."); setPct(""); void sh.reload();
  };
  const closeRule = async (id: string) => {
    const { error } = await supabase.rpc("admin_close_associate_rule_v1", { _rule: id, _to: closeDate[id] });
    if (error) { onNotice(errMsg(error.message)); return; }
    onNotice("Règle clôturée."); void sh.reload();
  };

  return (
    <>
      <Panel title="Vérité financière V1" subtitle="Seuls les paiements réellement encaissés et non remboursés comptent. Ticket gratuit = 0 FCFA.">
        {fin.error && <p className="text-sm text-destructive">{fin.error}</p>}
        <div className="grid grid-cols-2 gap-3 md:grid-cols-5">
          <Stat label="Revenu net encaissé" value={fcfa(f.net_revenue)} accent />
          <Stat label="Dont aujourd’hui" value={fcfa(f.net_revenue_today)} />
          <Stat label="Frais opérateur" value={fcfa(f.fees_total)} />
          <Stat label="Total débité" value={fcfa(f.debited_total)} />
          <Stat label="Net opérateur" value={f.provider_net_total == null ? "—" : fcfa(f.provider_net_total)} />
        </div>
        <p className="mt-3 text-xs text-muted-foreground">Tickets gratuits aujourd’hui : {s(f.free_passes_today ?? 0)} (0 revenu).</p>
        <div className="mt-3 rounded-xl border border-dashed border-border p-3 text-xs text-muted-foreground">
          <span className="font-semibold text-foreground">{s(legacy.label)}</span> — {s(legacy.count ?? 0)} lignes · {fcfa(legacy.amount)} (jamais compté comme revenu)
        </div>
        <div className="mt-4 overflow-x-auto">
          <table className="w-full min-w-[640px] text-left text-xs">
            <thead className="text-muted-foreground"><tr>{["Référence", "Type", "Statut", "Prix ticket", "Frais", "Débité", "Net opérateur", "Compté", "Date"].map((h) => <th key={h} className="px-2 py-2 font-medium">{h}</th>)}</tr></thead>
            <tbody>
              {txs.length === 0 && <tr><td colSpan={9} className="px-2 py-4 text-center text-muted-foreground">Aucune transaction de paiement.</td></tr>}
              {txs.map((t) => (
                <tr key={String(t.id)} className="border-t border-border">
                  <td className="px-2 py-2">{s(t.internal_reference)}</td><td className="px-2 py-2">{s(t.operation_type)}</td>
                  <td className="px-2 py-2">{s(t.status)}</td><td className="px-2 py-2">{fcfa(t.amount_base_fcfa)}</td>
                  <td className="px-2 py-2">{fcfa(t.fees_fcfa)}</td><td className="px-2 py-2">{fcfa(t.amount_total_fcfa)}</td>
                  <td className="px-2 py-2">{t.provider_net_amount_fcfa == null ? "—" : fcfa(t.provider_net_amount_fcfa)}</td>
                  <td className="px-2 py-2">{t.counted ? "Oui" : "Non"}</td><td className="px-2 py-2">{dt(t.created_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Panel>

      <Panel title="Parts Associés" subtitle="Calculées sur le revenu encaissé, avec la règle valable à la date du paiement. Aucun versement automatique.">
        {sh.error && <p className="text-sm text-destructive">{sh.error}</p>}
        <div className="overflow-x-auto">
          <table className="w-full min-w-[560px] text-left text-xs">
            <thead className="text-muted-foreground"><tr>{["Période", "Associé", "Revenu éligible", "Pourcentage", "Part calculée"].map((h) => <th key={h} className="px-2 py-2 font-medium">{h}</th>)}</tr></thead>
            <tbody>
              {shares.length === 0 && <tr><td colSpan={5} className="px-2 py-4 text-center text-muted-foreground">Aucune part : aucun revenu encaissé.</td></tr>}
              {shares.map((x, i) => (
                <tr key={i} className="border-t border-border">
                  <td className="px-2 py-2">{s(x.period)}</td><td className="px-2 py-2">{s(x.associate)}</td>
                  <td className="px-2 py-2">{fcfa(x.eligible_revenue)}</td><td className="px-2 py-2">{s(x.share_percent)} %</td>
                  <td className="px-2 py-2 font-semibold">{fcfa(x.share_amount)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <h3 className="mt-6 text-sm font-semibold text-foreground">Règles de répartition</h3>
        <div className="mt-2 overflow-x-auto">
          <table className="w-full min-w-[560px] text-left text-xs">
            <thead className="text-muted-foreground"><tr>{["Associé", "%", "Du", "Au", ""].map((h) => <th key={h} className="px-2 py-2 font-medium">{h}</th>)}</tr></thead>
            <tbody>
              {rules.length === 0 && <tr><td colSpan={5} className="px-2 py-4 text-center text-muted-foreground">Aucune règle.</td></tr>}
              {rules.map((r) => {
                const id = String(r.id);
                return (
                  <tr key={id} className="border-t border-border">
                    <td className="px-2 py-2">{s(r.display_name)}</td><td className="px-2 py-2">{s(r.share_percent)} %</td>
                    <td className="px-2 py-2">{s(r.effective_from)}</td><td className="px-2 py-2">{s(r.effective_to)}</td>
                    <td className="px-2 py-2">
                      <div className="flex gap-2">
                        <Input type="date" className="h-8 w-36" value={closeDate[id] ?? ""} onChange={(e) => setCloseDate({ ...closeDate, [id]: e.target.value })} aria-label="Date de fin" />
                        <Button size="sm" variant="outline" disabled={!closeDate[id]} onClick={() => void closeRule(id)}>Clôturer</Button>
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
        <div className="mt-4 grid gap-2 md:grid-cols-[1fr_120px_160px_auto]">
          <select className="h-10 rounded-md border border-border bg-background px-3 text-sm" value={assoc} onChange={(e) => setAssoc(e.target.value)} aria-label="Associé">
            <option value="">Choisir un associé…</option>
            {associates.map((a) => <option key={String(a.id)} value={String(a.id)}>{s(a.display_name)}</option>)}
          </select>
          <Input type="number" placeholder="%" value={pct} onChange={(e) => setPct(e.target.value)} aria-label="Pourcentage" />
          <Input type="date" value={from} onChange={(e) => setFrom(e.target.value)} aria-label="Date de début" />
          <Button onClick={() => void createRule()} disabled={!assoc || !pct || !from}>Ajouter la règle</Button>
        </div>
        {associates.length === 0 && <p className="mt-2 text-xs text-muted-foreground">Aucun associé enregistré dans le registre V1.</p>}
      </Panel>
    </>
  );
}

/* 6/7. Restrictions + force offline, 8. audit */
const RTYPES: { id: string; label: string }[] = [
  { id: "pool_blocked", label: "Bloquer les nouvelles courses" },
  { id: "shared_blocked", label: "Bloquer le partage" },
  { id: "access_blocked", label: "Bloquer l’accès (en ligne)" },
];

export function RestrictionsAuditV1({ onNotice }: { onNotice: Notice }) {
  const rs = useRpc<Row>(() => supabase.rpc("admin_list_driver_restrictions_v1"));
  const au = useRpc<Row[]>(() => supabase.rpc("admin_list_audit_events_v1", { _limit: 100 }));
  const [driver, setDriver] = useState("");
  const [type, setType] = useState("pool_blocked");
  const [reason, setReason] = useState("");
  const [liftReason, setLiftReason] = useState<Record<string, string>>({});
  const drivers = (rs.data?.drivers ?? []) as Row[];
  const list = (rs.data?.restrictions ?? []) as Row[];
  const refresh = () => { void rs.reload(); void au.reload(); };

  const apply = async () => {
    const { error } = await supabase.rpc("admin_create_driver_restriction_v1", { _driver: driver, _type: type, _reason: reason });
    if (error) { onNotice(errMsg(error.message)); return; }
    onNotice("Restriction appliquée."); setReason(""); refresh();
  };
  const offline = async () => {
    const { data, error } = await supabase.rpc("admin_force_driver_offline_v1", { _driver: driver, _reason: reason });
    if (error) { onNotice(errMsg(error.message)); return; }
    const kept = Number((data as Row | null)?.engaged_rides_kept ?? 0);
    onNotice(kept ? `Chauffeur hors ligne. ${kept} course(s) engagée(s) se poursuivent.` : "Chauffeur hors ligne.");
    setReason(""); refresh();
  };
  const lift = async (id: string) => {
    const { error } = await supabase.rpc("admin_lift_driver_restriction_v1", { _restriction: id, _reason: liftReason[id] ?? "" });
    if (error) { onNotice(errMsg(error.message)); return; }
    onNotice("Restriction levée."); refresh();
  };

  return (
    <>
      <Panel title="Restrictions chauffeur" subtitle="Une restriction n’empêche jamais de terminer une course déjà engagée.">
        <div className="grid gap-2 md:grid-cols-[1fr_1fr_1.4fr]">
          <select className="h-10 rounded-md border border-border bg-background px-3 text-sm" value={driver} onChange={(e) => setDriver(e.target.value)} aria-label="Chauffeur">
            <option value="">Choisir un chauffeur…</option>
            {drivers.map((d) => <option key={String(d.driver_id)} value={String(d.driver_id)}>{`${s(d.first_name)} ${d.last_name ? String(d.last_name) : ""} · ${s(d.vehicle_plate)}${d.is_online ? " · en ligne" : ""}`}</option>)}
          </select>
          <select className="h-10 rounded-md border border-border bg-background px-3 text-sm" value={type} onChange={(e) => setType(e.target.value)} aria-label="Type de restriction">
            {RTYPES.map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}
          </select>
          <Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Motif obligatoire" aria-label="Motif" />
        </div>
        <div className="mt-3 flex flex-wrap gap-2">
          <Button onClick={() => void apply()} disabled={!driver || !reason.trim()}>Appliquer la restriction</Button>
          <Button variant="outline" onClick={() => void offline()} disabled={!driver || !reason.trim()}>Forcer hors ligne</Button>
        </div>
        <div className="mt-5 overflow-x-auto">
          <table className="w-full min-w-[640px] text-left text-xs">
            <thead className="text-muted-foreground"><tr>{["Chauffeur", "Type", "Motif", "Depuis", "État", ""].map((h) => <th key={h} className="px-2 py-2 font-medium">{h}</th>)}</tr></thead>
            <tbody>
              {list.length === 0 && <tr><td colSpan={6} className="px-2 py-4 text-center text-muted-foreground">Aucune restriction.</td></tr>}
              {list.map((r) => {
                const id = String(r.id);
                return (
                  <tr key={id} className="border-t border-border">
                    <td className="px-2 py-2">{s(r.driver_name)}</td>
                    <td className="px-2 py-2">{RTYPES.find((t) => t.id === r.restriction_type)?.label ?? s(r.restriction_type)}</td>
                    <td className="px-2 py-2">{s(r.reason)}</td><td className="px-2 py-2">{dt(r.starts_at)}</td>
                    <td className="px-2 py-2">{r.active ? <span className="text-destructive">Active</span> : r.lifted_at ? `Levée (${s(r.lift_reason)})` : "Expirée"}</td>
                    <td className="px-2 py-2">
                      {r.active ? (
                        <div className="flex gap-2">
                          <Input className="h-8 w-40" placeholder="Motif de levée" value={liftReason[id] ?? ""} onChange={(e) => setLiftReason({ ...liftReason, [id]: e.target.value })} aria-label="Motif de levée" />
                          <Button size="sm" variant="outline" disabled={!liftReason[id]?.trim()} onClick={() => void lift(id)}>Lever</Button>
                        </div>
                      ) : null}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </Panel>

      <Panel title="Journal d’audit V1" subtitle="Actions administratives à effet métier. Aucune consultation n’est journalisée.">
        {au.error && <p className="text-sm text-destructive">{au.error}</p>}
        <div className="overflow-x-auto">
          <table className="w-full min-w-[640px] text-left text-xs">
            <thead className="text-muted-foreground"><tr>{["Date", "Action", "Cible", "Motif", "Détails"].map((h) => <th key={h} className="px-2 py-2 font-medium">{h}</th>)}</tr></thead>
            <tbody>
              {(au.data ?? []).length === 0 && <tr><td colSpan={5} className="px-2 py-4 text-center text-muted-foreground">Journal vide.</td></tr>}
              {(au.data ?? []).map((e) => (
                <tr key={String(e.id)} className="border-t border-border align-top">
                  <td className="px-2 py-2">{dt(e.occurred_at)}</td><td className="px-2 py-2">{s(e.event_type)}</td>
                  <td className="px-2 py-2">{s(e.entity_type)}</td><td className="px-2 py-2">{s(e.reason)}</td>
                  <td className="px-2 py-2 font-mono text-[10px] text-muted-foreground">{JSON.stringify(e.metadata)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Panel>
    </>
  );
}
