import { createServerFn } from "@tanstack/react-start";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";

export type XfinChecklist = {
  environment: "SANDBOX" | "PRODUCTION";
  keyPrefix: "conforme" | "non conforme";
  credentials: "manquants" | "configurés";
  appActive: "inconnu" | "oui" | "non";
  feeOwner: "inconnu" | "compatible" | "incompatible";
  webhookSecret: "manquant" | "configuré";
  error: string | null;
};

/** Checklist Superadmin non sensible. Aucun appel réseau tant que les credentials manquent. */
export const getXfinChecklist = createServerFn({ method: "GET" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }): Promise<XfinChecklist> => {
    const { data: isAdmin } = await context.supabase.rpc("has_role", { _user_id: context.userId, _role: "super_admin" });
    if (!isAdmin) throw new Error("FORBIDDEN");
    const x = await import("./xfin.server");
    const p = x.xfinSecretsPresence();
    const out: XfinChecklist = {
      environment: p.environment,
      keyPrefix: p.keyPrefixOk ? "conforme" : "non conforme",
      credentials: p.credentials ? "configurés" : "manquants",
      appActive: "inconnu",
      feeOwner: "inconnu",
      webhookSecret: p.webhookSecret ? "configuré" : "manquant",
      error: null,
    };
    if (!p.credentials || !p.keyPrefixOk) return out;
    try {
      const me = await x.getMe();
      out.appActive = (me.status ?? "").toLowerCase() === "active" ? "oui" : "non";
      out.feeOwner = (me.paymentFeeOwner ?? "").toUpperCase() === "CUSTOMER" ? "compatible" : "incompatible";
    } catch (e) {
      out.error = e instanceof x.XfinError ? e.code : "XFIN_UNREACHABLE";
    }
    return out;
  });

/* ---------------- xFin SANDBOX : parcours chauffeur (argent simulé) ---------------- */
type Operator = "AIRTEL_MONEY" | "MOOV_MONEY";
const isOperator = (v: unknown): v is Operator => v === "AIRTEL_MONEY" || v === "MOOV_MONEY";

export type SandboxState = {
  available: boolean;
  reason: "OK" | "NOT_SANDBOX" | "NOT_CONFIGURED" | "NOT_ALLOWED";
  pending: { id: string; total: number; operator: string | null } | null;
};

async function sandboxContext(userId: string) {
  const x = await import("./xfin.server");
  const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
  const p = x.xfinSecretsPresence();
  const { data: allowed } = await supabaseAdmin.rpc("xfin_sandbox_tester_enabled" as never, { _driver: userId } as never);
  let reason: SandboxState["reason"] = "OK";
  if (p.environment !== "SANDBOX") reason = "NOT_SANDBOX";
  else if (!p.credentials || !p.keyPrefixOk) reason = "NOT_CONFIGURED";
  else if (allowed !== true) reason = "NOT_ALLOWED";
  return { x, admin: supabaseAdmin, reason };
}

export const getSandboxPaymentState = createServerFn({ method: "GET" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }): Promise<SandboxState> => {
    const { admin, reason } = await sandboxContext(context.userId);
    if (reason === "NOT_SANDBOX") return { available: false, reason, pending: null };
    const { data } = await admin.from("payment_transactions")
      .select("id, amount_total_fcfa, operator")
      .eq("payer_driver_id", context.userId).eq("provider_environment" as never, "SANDBOX" as never).eq("status", "pending")
      .order("created_at", { ascending: false }).limit(1).maybeSingle();
    const row = data as { id: string; amount_total_fcfa: number; operator: string | null } | null;
    return { available: reason === "OK", reason, pending: row ? { id: row.id, total: row.amount_total_fcfa, operator: row.operator } : null };
  });

export const getSandboxFees = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: { operator: string }) => { if (!isOperator(d.operator)) throw new Error("OPERATOR_INVALID"); return { operator: d.operator }; })
  .handler(async ({ data, context }) => {
    const { x, reason } = await sandboxContext(context.userId);
    if (reason !== "OK") throw new Error(`SANDBOX_${reason}`);
    try {
      const f = x.parseFees(await x.getFees(data.operator));
      return { base: x.DAY_TICKET_AMOUNT_FCFA, fee: f.providerFee, total: x.DAY_TICKET_AMOUNT_FCFA + f.providerFee };
    } catch (e) { throw new Error(e instanceof x.XfinError ? e.code : "XFIN_UNREACHABLE"); }
  });

export const startSandboxPayment = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: { operator: string; phone: string }) => {
    if (!isOperator(d.operator)) throw new Error("OPERATOR_INVALID");
    if (typeof d.phone !== "string" || d.phone.length > 20) throw new Error("PHONE_INVALID");
    return { operator: d.operator, phone: d.phone };
  })
  .handler(async ({ data, context }) => {
    const { x, admin, reason } = await sandboxContext(context.userId);
    if (reason !== "OK") throw new Error(`SANDBOX_${reason}`);
    let phone: string;
    try { phone = x.toXfinLocalPhone(data.phone); } catch { throw new Error("PHONE_INVALID"); }
    let fee: number;
    try { fee = x.parseFees(await x.getFees(data.operator)).providerFee; } catch (e) { throw new Error(e instanceof x.XfinError ? e.code : "XFIN_UNREACHABLE"); }
    const { data: started, error } = await admin.rpc("start_sandbox_day_payment_v1" as never,
      { _driver: context.userId, _operator: data.operator, _msisdn: phone, _fees: fee } as never);
    if (error) throw new Error((error.message.match(/[A-Z_]{6,}/) ?? ["START_FAILED"])[0]);
    const txId = (started as { transaction_id: string }).transaction_id;
    try {
      const res = await x.createPayment({ operatorCode: data.operator, buyerPhone: phone, appTransactionRef: x.buildAppTransactionRef(txId) });
      await admin.rpc("attach_sandbox_xfin_reference_v1" as never, { _tx: txId, _ref: res.xfinReference } as never);
      return { transactionId: txId, status: "PENDING" as const, total: 1000 + fee };
    } catch (e) {
      const code = e instanceof x.XfinError ? e.code : "XFIN_UNREACHABLE";
      await admin.rpc("fail_sandbox_payment_v1" as never, { _tx: txId, _code: code } as never);
      throw new Error(code);
    }
  });

/** Polling serveur : seul xFin (via GET /transactions) peut rendre SUCCESS. */
export const pollSandboxPayment = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: { transactionId: string }) => { if (!/^[0-9a-f-]{36}$/.test(d.transactionId)) throw new Error("TX_INVALID"); return d; })
  .handler(async ({ data, context }) => {
    const { x, admin } = await sandboxContext(context.userId);
    const { data: tx } = await admin.from("payment_transactions")
      .select("id, status, xfin_reference, error_code, payer_driver_id, provider_environment" as never)
      .eq("id", data.transactionId).maybeSingle();
    const t = tx as { id: string; status: string; xfin_reference: string | null; error_code: string | null; payer_driver_id: string; provider_environment: string } | null;
    if (!t || t.payer_driver_id !== context.userId || t.provider_environment !== "SANDBOX") throw new Error("TX_NOT_FOUND");
    if (t.status !== "pending") return { status: t.status.toUpperCase(), reason: t.error_code };
    if (!t.xfin_reference) return { status: "PENDING", reason: null };
    let remote;
    try { remote = await x.getTransaction(t.xfin_reference); } catch { return { status: "PENDING", reason: null }; }
    const resolution = x.toResolution({ ...remote, xfinReference: t.xfin_reference }, "polling");
    const { error } = await admin.rpc("apply_xfin_transaction_update", resolution as never);
    if (error) { console.error("[xfin-sandbox] apply failed", { code: error.code }); return { status: "PENDING", reason: null }; }
    const fr = resolution._status === "FAILED" ? x.failureReasonOf(remote) : null;
    if (fr) await admin.rpc("set_sandbox_failure_reason_v1" as never, { _tx: t.id, _code: fr } as never);
    return { status: resolution._status === "UNKNOWN" ? "PENDING" : resolution._status, reason: fr };
  });
