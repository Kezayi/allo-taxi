// Paiement test xFin SANDBOX (argent simulé) — visible uniquement pour un chauffeur autorisé par le Superadmin.
import { useEffect, useRef, useState } from "react";
import { useServerFn } from "@tanstack/react-start";
import { FlaskConical, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { getSandboxFees, getSandboxPaymentState, pollSandboxPayment, startSandboxPayment, type SandboxState } from "@/lib/xfin.functions";

const REASONS: Record<string, string> = {
  INSUFFICIENT_FUNDS: "Solde insuffisant.",
  USER_REJECTED: "Paiement refusé sur le téléphone.",
  TIMEOUT: "Délai de validation dépassé.",
  INVALID_ACCOUNT: "Compte mobile money invalide.",
  PAYMENT_ALREADY_PENDING: "Un paiement est déjà en cours.",
  PASS_ALREADY_ACTIVE: "Votre accès est déjà actif.",
  PHONE_INVALID: "Numéro invalide.",
};
const say = (code: string | null | undefined) => (code && REASONS[code]) || "Paiement non abouti. Vous pouvez réessayer.";

export function SandboxPayment({ onActivated }: { onActivated: () => void }) {
  const fetchState = useServerFn(getSandboxPaymentState);
  const fetchFees = useServerFn(getSandboxFees);
  const start = useServerFn(startSandboxPayment);
  const poll = useServerFn(pollSandboxPayment);
  const [state, setState] = useState<SandboxState | null>(null);
  const [operator, setOperator] = useState<"AIRTEL_MONEY" | "MOOV_MONEY">("AIRTEL_MONEY");
  const [phone, setPhone] = useState("");
  const [fees, setFees] = useState<{ fee: number; total: number } | null>(null);
  const [txId, setTxId] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const timer = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => { void fetchState().then((s) => { setState(s); if (s.pending) setTxId(s.pending.id); }).catch(() => setState(null)); }, [fetchState]);
  useEffect(() => {
    if (!state?.available) return;
    setFees(null);
    void fetchFees({ data: { operator } }).then(setFees).catch(() => setFees(null));
  }, [operator, state?.available, fetchFees]);

  useEffect(() => {
    if (!txId) return;
    const tick = async () => {
      try {
        const r = await poll({ data: { transactionId: txId } });
        if (r.status === "SUCCESS") { stop(); setMsg("Paiement test confirmé. Accès activé."); onActivated(); }
        else if (r.status !== "PENDING") { stop(); setMsg(say(r.reason)); }
      } catch { /* réseau : on retente au prochain cycle */ }
    };
    const stop = () => { if (timer.current) clearInterval(timer.current); timer.current = null; setTxId(null); };
    void tick();
    timer.current = setInterval(() => void tick(), 4000);
    return () => { if (timer.current) clearInterval(timer.current); };
  }, [txId, poll, onActivated]);

  if (!state || state.reason === "NOT_SANDBOX" || state.reason === "NOT_ALLOWED") return null;

  async function pay() {
    setBusy(true); setMsg(null);
    try {
      const r = await start({ data: { operator, phone } });
      setTxId(r.transactionId);
    } catch (e) {
      setMsg(say(e instanceof Error ? e.message : null));
    }
    setBusy(false);
  }

  return (
    <div className="mt-6 rounded-md border border-primary/40 bg-primary/5 p-4 text-left">
      <p className="flex items-center gap-2 text-xs font-bold uppercase text-primary"><FlaskConical className="size-4" />Mode SANDBOX — aucun argent réel</p>
      {state.reason === "NOT_CONFIGURED" ? (
        <p className="mt-2 text-xs text-muted-foreground">Paiement test non configuré.</p>
      ) : txId ? (
        <p className="mt-3 flex items-center gap-2 text-sm"><Loader2 className="size-4 animate-spin" />En attente de validation sur le téléphone…</p>
      ) : (
        <div className="mt-3 grid gap-2">
          <div className="grid grid-cols-2 gap-2">
            {(["AIRTEL_MONEY", "MOOV_MONEY"] as const).map((o) => (
              <Button key={o} type="button" variant={operator === o ? "default" : "secondary"} onClick={() => setOperator(o)}>{o === "AIRTEL_MONEY" ? "Airtel Money" : "Moov Money"}</Button>
            ))}
          </div>
          <Input value={phone} onChange={(e) => setPhone(e.target.value)} inputMode="tel" placeholder="Numéro mobile money" aria-label="Numéro mobile money" className="h-11" />
          <p className="text-xs text-muted-foreground">
            Ticket 1 000 FCFA · Frais {fees ? `${fees.fee.toLocaleString("fr-FR")} FCFA` : "…"} · Total {fees ? `${fees.total.toLocaleString("fr-FR")} FCFA` : "…"}
          </p>
          <Button type="button" disabled={busy || !fees || phone.trim().length < 8} onClick={() => void pay()} className="h-12 font-bold">Payer (test)</Button>
        </div>
      )}
      {msg && <p role="status" className="mt-2 text-sm">{msg}</p>}
    </div>
  );
}
