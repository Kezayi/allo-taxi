import { CheckCircle2, Eye, FileCheck2, History, Loader2, RotateCcw, ShieldCheck, UserCog } from "lucide-react";
import { useCallback, useEffect, useState } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Chip, DOC_LABELS, docStatusChip } from "@/components/driver/onboarding";
import { supabase } from "@/integrations/supabase/client";
import { cn } from "@/lib/utils";

type Dossier = {
  driver_id: string;
  first_name: string;
  last_name: string | null;
  driver_status: string;
  onboarding_status: string;
  global_state: string;
  vehicle_id: string | null;
  vehicle_label: string | null;
  vehicle_plate: string | null;
  vehicle_validation: string | null;
  registered_seats: number | null;
  passenger_capacity: number | null;
  approved_docs: number;
  pending_docs: number;
  correction_docs: number;
  expired_docs: number;
  is_demo: boolean;
};

type Check = { method: string; result: string; decision: string | null; reason: string | null; created_at: string };
type DossierDoc = {
  document_id: string;
  doc_type: string;
  version: number;
  is_current: boolean;
  status: string;
  raw_status: string;
  expires_on: string | null;
  issued_on: string | null;
  mime_type: string | null;
  size_bytes: number | null;
  created_at: string;
  checks: Check[];
};
type DossierDetail = {
  driver: { user_id: string; first_name: string; last_name: string | null; status: string; onboarding_status: string; is_demo: boolean };
  global_state: string;
  vehicle: {
    id: string; make: string | null; model: string | null; color: string | null; plate: string | null; has_ac: boolean;
    registered_seats: number | null; passenger_capacity: number | null; validation_status: string; validated_at: string | null;
  } | null;
  documents: DossierDoc[];
};

const STATE_LABELS: Record<string, { label: string; tone: "live" | "gold" | "danger" | "muted" }> = {
  approved: { label: "Dossier validé", tone: "live" },
  pending_review: { label: "En attente d’examen", tone: "gold" },
  correction_required: { label: "Correction demandée", tone: "danger" },
  document_expired: { label: "Pièce expirée", tone: "danger" },
};

const FILTERS = {
  all: "Tous",
  pending_review: "En attente",
  correction_required: "Correction demandée",
  document_expired: "Expirés",
  approved: "Validés",
} as const;

function frDateTime(value: string | null) {
  return value ? new Date(value).toLocaleString("fr-FR", { timeZone: "Africa/Libreville", dateStyle: "short", timeStyle: "short" }) : "—";
}
function frDate(value: string | null) {
  return value ? new Date(value).toLocaleDateString("fr-FR", { timeZone: "Africa/Libreville", day: "2-digit", month: "2-digit", year: "numeric" }) : "—";
}

export function DriverDossiers({ onNotice }: { onNotice: (message: string) => void }) {
  const [rows, setRows] = useState<Dossier[]>([]);
  const [filter, setFilter] = useState<keyof typeof FILTERS>("all");
  const [openId, setOpenId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("admin_list_driver_dossiers");
    setLoading(false);
    if (error) return onNotice("Dossiers indisponibles.");
    setRows((data ?? []) as Dossier[]);
  }, [onNotice]);

  useEffect(() => { void load(); }, [load]);

  const shown = rows.filter((r) => filter === "all" || r.global_state === filter);

  return (
    <section className="glass-panel mt-4 p-5 sm:p-7">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="flex items-center gap-2 text-sm font-semibold"><UserCog className="size-4 text-primary" />Dossiers chauffeurs</p>
          <p className="mt-1 text-xs text-muted-foreground">{rows.length} dossiers · {rows.filter((r) => r.pending_docs > 0).length} avec des pièces à examiner</p>
        </div>
        <div className="flex flex-wrap gap-1">
          {(Object.keys(FILTERS) as (keyof typeof FILTERS)[]).map((k) => (
            <Button key={k} size="sm" variant={filter === k ? "default" : "outline"} onClick={() => setFilter(k)} className="h-8 text-[11px]">{FILTERS[k]}</Button>
          ))}
          <Button size="sm" variant="ghost" onClick={() => void load()} className="h-8"><RotateCcw className="size-3.5" /></Button>
        </div>
      </div>

      <div className="mt-5 space-y-2">
        {loading && <p className="flex items-center gap-2 text-xs text-muted-foreground"><Loader2 className="size-4 animate-spin" />Chargement…</p>}
        {!loading && shown.length === 0 && <p className="text-xs text-muted-foreground">Aucun dossier dans cette catégorie.</p>}
        {shown.map((r) => {
          const state = STATE_LABELS[r.global_state] ?? STATE_LABELS["pending_review"]!;
          return (
            <button key={r.driver_id} type="button" onClick={() => setOpenId(r.driver_id)}
              className="grid w-full gap-3 rounded-md border border-border bg-secondary/60 p-4 text-left transition-colors hover:border-primary/40 md:grid-cols-[minmax(0,1fr)_auto] md:items-center">
              <div className="min-w-0">
                <div className="flex flex-wrap items-center gap-2">
                  <p className="text-sm font-semibold">{r.first_name} {r.last_name ?? ""}</p>
                  <Chip tone={state.tone}>{state.label}</Chip>
                  {r.is_demo && <Chip tone="muted">Démo</Chip>}
                </div>
                <p className="mt-1 text-xs text-muted-foreground">
                  {r.vehicle_label ?? "Aucun véhicule actif"}{r.vehicle_plate ? ` · ` : ""}
                  {r.vehicle_plate && <strong className="uppercase text-primary">{r.vehicle_plate}</strong>}
                  {r.registered_seats ? ` · ${r.registered_seats} places (${r.passenger_capacity} passagers)` : " · places non renseignées"}
                </p>
                <p className="mt-1 text-[11px] text-muted-foreground">
                  {r.approved_docs}/8 approuvées · {r.pending_docs} en attente
                  {r.correction_docs > 0 ? ` · ${r.correction_docs} à corriger` : ""}
                  {r.expired_docs > 0 ? ` · ${r.expired_docs} expirée(s)` : ""}
                </p>
              </div>
              <span className="flex items-center gap-2 text-xs text-primary"><Eye className="size-4" />Ouvrir le dossier</span>
            </button>
          );
        })}
      </div>

      <DossierSheet driverId={openId} onClose={() => setOpenId(null)} onChanged={() => void load()} onNotice={onNotice} />
    </section>
  );
}

function DossierSheet({ driverId, onClose, onChanged, onNotice }: { driverId: string | null; onClose: () => void; onChanged: () => void; onNotice: (m: string) => void }) {
  const [detail, setDetail] = useState<DossierDetail | null>(null);
  const [reasons, setReasons] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!driverId) return setDetail(null);
    const { data, error } = await supabase.rpc("admin_get_driver_dossier", { _driver_id: driverId });
    if (error) return onNotice("Dossier illisible.");
    setDetail(data as unknown as DossierDetail);
  }, [driverId, onNotice]);

  useEffect(() => { void load(); }, [load]);

  async function openFile(documentId: string) {
    setBusy(documentId);
    const { data, error } = await supabase.rpc("get_document_storage_ref", { _document_id: documentId });
    if (error || !data) { setBusy(null); return onNotice("Pièce introuvable."); }
    const ref = data as unknown as { bucket: string; path: string };
    const { data: signed, error: signError } = await supabase.storage.from(ref.bucket).createSignedUrl(ref.path, 120);
    setBusy(null);
    if (signError || !signed) return onNotice("Lien de consultation indisponible.");
    window.open(signed.signedUrl, "_blank", "noopener,noreferrer");
  }

  async function reviewDoc(documentId: string, decision: "approve" | "request_correction") {
    const reason = reasons[documentId]?.trim() ?? "";
    if (decision === "request_correction" && !reason) return onNotice("Indiquez le motif de la correction.");
    setBusy(documentId);
    const { error } = await supabase.rpc("review_driver_document", { _document_id: documentId, _decision: decision, ...(reason ? { _reason: reason } : {}) });
    setBusy(null);
    if (error) return onNotice("Décision non enregistrée.");
    setReasons((current) => ({ ...current, [documentId]: "" }));
    onNotice(decision === "approve" ? "Pièce approuvée." : "Correction demandée au chauffeur.");
    await load();
    onChanged();
  }

  async function reviewVehicle(decision: "approve" | "request_correction") {
    if (!detail?.vehicle) return;
    const key = `vehicle-${detail.vehicle.id}`;
    const reason = reasons[key]?.trim() ?? "";
    if (decision === "request_correction" && !reason) return onNotice("Indiquez le motif de la correction.");
    setBusy(key);
    const { error } = await supabase.rpc("review_driver_vehicle", { _vehicle_id: detail.vehicle.id, _decision: decision, _reason: reason || undefined });
    setBusy(null);
    if (error) {
      if (error.message.includes("SEATS_MISSING")) return onNotice("Renseignez les places homologuées avant de valider.");
      if (error.message.includes("CAPACITY_INCONSISTENT")) return onNotice("Capacité incohérente avec les places homologuées.");
      return onNotice("Décision non enregistrée.");
    }
    setReasons((current) => ({ ...current, [key]: "" }));
    onNotice(decision === "approve" ? "Véhicule validé." : "Correction demandée sur le véhicule.");
    await load();
    onChanged();
  }

  const current = detail?.documents.filter((d) => d.is_current) ?? [];
  const history = detail?.documents.filter((d) => !d.is_current) ?? [];
  const state = detail ? STATE_LABELS[detail.global_state] ?? STATE_LABELS["pending_review"]! : null;
  const vehicleKey = detail?.vehicle ? `vehicle-${detail.vehicle.id}` : "";

  return (
    <Sheet open={Boolean(driverId)} onOpenChange={(open) => { if (!open) onClose(); }}>
      <SheetContent side="right" className="w-full overflow-y-auto sm:max-w-2xl">
        <SheetHeader>
          <SheetTitle>{detail ? `${detail.driver.first_name} ${detail.driver.last_name ?? ""}` : "Dossier chauffeur"}</SheetTitle>
          <SheetDescription>Contrôle humain des pièces et du véhicule. Chaque décision est enregistrée définitivement.</SheetDescription>
        </SheetHeader>

        {!detail ? (
          <div className="grid place-items-center py-16"><Loader2 className="size-6 animate-spin text-muted-foreground" /></div>
        ) : (
          <div className="mt-5 space-y-5">
            {state && <Chip tone={state.tone}>{state.label}</Chip>}

            <section className="rounded-md border border-border bg-secondary/60 p-4">
              <p className="flex items-center gap-2 text-sm font-semibold"><ShieldCheck className="size-4 text-primary" />Véhicule actif</p>
              {!detail.vehicle ? (
                <p className="mt-2 text-xs text-muted-foreground">Aucun véhicule actif enregistré.</p>
              ) : (
                <>
                  <p className="mt-2 text-xs text-muted-foreground">
                    {[detail.vehicle.make, detail.vehicle.model, detail.vehicle.color].filter(Boolean).join(" · ")} · <strong className="uppercase text-primary">{detail.vehicle.plate}</strong> · {detail.vehicle.has_ac ? "Climatisé" : "Standard"}
                  </p>
                  <p className="mt-1 text-xs text-muted-foreground">
                    Carte grise déclarée : {detail.vehicle.registered_seats ?? "—"} places homologuées → {detail.vehicle.passenger_capacity ?? "—"} passagers.
                  </p>
                  <p className="mt-1 text-[11px] text-muted-foreground">Comparez ces valeurs avec la carte grise avant d’approuver. En cas d’écart, demandez une correction : les données ne sont jamais modifiées automatiquement.</p>
                  <div className="mt-3 flex flex-wrap items-center gap-2">
                    <Chip tone={detail.vehicle.validation_status === "approved" ? "live" : detail.vehicle.validation_status === "rejected" ? "danger" : "gold"}>
                      {detail.vehicle.validation_status === "approved" ? `Validé le ${frDate(detail.vehicle.validated_at)}` : detail.vehicle.validation_status === "rejected" ? "Correction demandée" : "En attente"}
                    </Chip>
                  </div>
                  <div className="mt-3 flex flex-wrap items-center gap-2">
                    <Input value={reasons[vehicleKey] ?? ""} onChange={(e) => setReasons({ ...reasons, [vehicleKey]: e.target.value })} placeholder="Motif de la correction" className="h-9 max-w-xs text-xs" />
                    <Button size="sm" disabled={busy === vehicleKey} onClick={() => void reviewVehicle("approve")} className="h-9 bg-live text-foreground hover:bg-live/90"><CheckCircle2 className="size-3.5" />Valider</Button>
                    <Button size="sm" variant="outline" disabled={busy === vehicleKey} onClick={() => void reviewVehicle("request_correction")} className="h-9 text-destructive">Demander une correction</Button>
                  </div>
                </>
              )}
            </section>

            <section>
              <p className="flex items-center gap-2 text-sm font-semibold"><FileCheck2 className="size-4 text-primary" />Pièces courantes</p>
              <div className="mt-3 space-y-3">
                {current.length === 0 && <p className="text-xs text-muted-foreground">Aucune pièce déposée.</p>}
                {current.map((doc) => {
                  const chip = docStatusChip(doc.status);
                  return (
                    <div key={doc.document_id} className={cn("rounded-md border border-border bg-secondary/60 p-4", doc.status === "rejected" && "border-destructive/40")}>
                      <div className="flex flex-wrap items-center justify-between gap-2">
                        <p className="text-sm font-semibold">{DOC_LABELS[doc.doc_type] ?? doc.doc_type} <span className="text-[11px] font-normal text-muted-foreground">v{doc.version}</span></p>
                        <Chip tone={chip.tone}>{chip.label}</Chip>
                      </div>
                      <p className="mt-1 text-[11px] text-muted-foreground">
                        Déposée le {frDateTime(doc.created_at)}{doc.expires_on ? ` · Échéance ${frDate(doc.expires_on)}` : ""}{doc.size_bytes ? ` · ${Math.round(doc.size_bytes / 1024)} Ko` : ""}
                      </p>
                      <div className="mt-3 flex flex-wrap items-center gap-2">
                        <Button size="sm" variant="outline" disabled={busy === doc.document_id} onClick={() => void openFile(doc.document_id)} className="h-9"><Eye className="size-3.5" />Consulter</Button>
                        <Input value={reasons[doc.document_id] ?? ""} onChange={(e) => setReasons({ ...reasons, [doc.document_id]: e.target.value })} placeholder="Motif de la correction" className="h-9 max-w-[14rem] text-xs" />
                        <Button size="sm" disabled={busy === doc.document_id} onClick={() => void reviewDoc(doc.document_id, "approve")} className="h-9 bg-live text-foreground hover:bg-live/90"><CheckCircle2 className="size-3.5" />Approuver</Button>
                        <Button size="sm" variant="outline" disabled={busy === doc.document_id} onClick={() => void reviewDoc(doc.document_id, "request_correction")} className="h-9 text-destructive">Correction</Button>
                      </div>
                      {doc.checks.length > 0 && (
                        <ul className="mt-3 space-y-1 border-t border-border pt-3">
                          {doc.checks.map((c, index) => (
                            <li key={index} className="text-[11px] text-muted-foreground">
                              {frDateTime(c.created_at)} · {c.method === "human" ? "Contrôle humain" : "Contrôle automatique"} · {c.decision === "approve" ? "approuvé" : "correction demandée"}{c.reason ? ` — ${c.reason}` : ""}
                            </li>
                          ))}
                        </ul>
                      )}
                    </div>
                  );
                })}
              </div>
            </section>

            {history.length > 0 && (
              <section>
                <p className="flex items-center gap-2 text-sm font-semibold"><History className="size-4 text-primary" />Versions antérieures</p>
                <ul className="mt-3 space-y-2">
                  {history.map((doc) => (
                    <li key={doc.document_id} className="flex flex-wrap items-center justify-between gap-2 rounded-md border border-border bg-background/40 p-3 text-[11px] text-muted-foreground">
                      <span>{DOC_LABELS[doc.doc_type] ?? doc.doc_type} · v{doc.version} · {frDateTime(doc.created_at)}</span>
                      <Button size="sm" variant="ghost" className="h-7 text-[11px]" disabled={busy === doc.document_id} onClick={() => void openFile(doc.document_id)}><Eye className="size-3" />Consulter</Button>
                    </li>
                  ))}
                </ul>
              </section>
            )}
          </div>
        )}
      </SheetContent>
    </Sheet>
  );
}
