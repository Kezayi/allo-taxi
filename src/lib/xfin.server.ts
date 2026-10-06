// Client serveur xFin (LOT 3C) — manuel officiel xFin v1, septembre 2026.
// Dormant : sans XFIN_APP_KEY/XFIN_APP_SECRET, aucun appel réseau n'est effectué
// et toute opération lève XFIN_NOT_CONFIGURED. Le mode PAID reste verrouillé en base
// par public.xfin_integration_ready() = false. Aucun secret n'est jamais renvoyé ni journalisé.
import { createHmac, timingSafeEqual } from "node:crypto";

export const XFIN_DEFAULT_BASE_URL = "https://bo.xfin.pro/v1";
export const XFIN_SANDBOX_BASE_URL = "https://portail.xfin.pro/portail/sandbox/v1";
export type XfinEnvironment = "SANDBOX" | "PRODUCTION";
/** XFIN_ENV absent ou invalide ⇒ PRODUCTION (le verrou PAID reste fermé en base). */
export function xfinEnvironment(): XfinEnvironment {
  return (process.env["XFIN_ENV"] ?? "").toUpperCase() === "SANDBOX" ? "SANDBOX" : "PRODUCTION";
}
export const XFIN_V1_OPERATORS = ["AIRTEL_MONEY", "MOOV_MONEY"] as const;
export type XfinOperator = (typeof XFIN_V1_OPERATORS)[number];
export const DAY_TICKET_AMOUNT_FCFA = 1000;

export type XfinProviderStatus = "PENDING" | "SUCCESS" | "FAILED" | "UNKNOWN";

export class XfinError extends Error {
  constructor(readonly code: string, readonly httpStatus?: number, readonly retryable = false) {
    super(code);
  }
}
export class XfinNotConfiguredError extends XfinError {
  constructor() { super("XFIN_NOT_CONFIGURED"); }
}

interface XfinEnv { baseUrl: string; appKey: string | undefined; appSecret: string | undefined; webhookSecret: string | undefined }
function readEnv(): XfinEnv {
  const sandbox = xfinEnvironment() === "SANDBOX";
  return {
    baseUrl: sandbox ? XFIN_SANDBOX_BASE_URL : process.env["XFIN_BASE_URL"] || XFIN_DEFAULT_BASE_URL,
    appKey: process.env["XFIN_APP_KEY"] || undefined,
    appSecret: process.env["XFIN_APP_SECRET"] || undefined,
    webhookSecret: process.env["XFIN_WEBHOOK_SIGNATURE_SECRET"] || undefined,
  };
}

/** Checklist non sensible : uniquement des booléens, jamais de valeur. */
export function xfinSecretsPresence() {
  const e = readEnv();
  const env = xfinEnvironment();
  // En Sandbox, seules des clés sbx_ sont acceptées ; en Production, jamais de clés sbx_.
  const prefixOk = env === "SANDBOX"
    ? Boolean(e.appKey?.startsWith("sbx_pk_") && e.appSecret?.startsWith("sbx_sk_"))
    : !e.appKey?.startsWith("sbx_") && !e.appSecret?.startsWith("sbx_");
  return { environment: env, credentials: Boolean(e.appKey && e.appSecret), keyPrefixOk: prefixOk, webhookSecret: Boolean(e.webhookSecret) };
}

/** Mapping HTTP du manuel : retry uniquement sur 502 (erreur technique agrégateur). */
export function mapHttpError(status: number): XfinError {
  switch (status) {
    case 400: return new XfinError("XFIN_BAD_REQUEST", 400);
    case 401: return new XfinError("XFIN_UNAUTHORIZED", 401);
    case 403: return new XfinError("XFIN_FORBIDDEN", 403);
    case 404: return new XfinError("XFIN_NOT_FOUND", 404);
    case 409: return new XfinError("XFIN_CONFLICT", 409);
    case 502: return new XfinError("XFIN_AGGREGATOR_ERROR", 502, true);
    default: return new XfinError("XFIN_HTTP_ERROR", status, status >= 500);
  }
}

export function mapProviderStatus(s: unknown): XfinProviderStatus {
  const v = typeof s === "string" ? s.toUpperCase() : "";
  return v === "PENDING" || v === "SUCCESS" || v === "FAILED" ? v : "UNKNOWN";
}

async function request<T>(method: "GET" | "POST", path: string, opts: { query?: Record<string, string>; body?: unknown; fetchImpl?: typeof fetch } = {}): Promise<T> {
  const env = readEnv();
  if (!env.appKey || !env.appSecret) throw new XfinNotConfiguredError(); // aucun appel réseau
  if (!xfinSecretsPresence().keyPrefixOk) throw new XfinError("XFIN_KEY_ENVIRONMENT_MISMATCH");
  const url = new URL(env.baseUrl.replace(/\/$/, "") + path);
  for (const [k, v] of Object.entries(opts.query ?? {})) url.searchParams.set(k, v);
  const doFetch = opts.fetchImpl ?? fetch;
  for (let attempt = 0; attempt < 2; attempt++) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 15_000);
    let res: Response;
    try {
      res = await doFetch(url, {
        method,
        signal: ctrl.signal,
        headers: { "X-App-Key": env.appKey as string, "X-App-Secret": env.appSecret as string, "Content-Type": "application/json", Accept: "application/json" },
        body: opts.body === undefined ? null : JSON.stringify(opts.body),
      });
    } catch {
      clearTimeout(timer);
      if (attempt === 0 && method === "GET") continue;
      throw new XfinError("XFIN_NETWORK_ERROR", undefined, true);
    }
    clearTimeout(timer);
    if (res.ok) return (await res.json()) as T;
    const err = mapHttpError(res.status);
    // Retry unique sur 502 ; jamais sur POST /payments pour éviter un double débit.
    if (err.retryable && res.status === 502 && attempt === 0 && method === "GET") { await new Promise((r) => setTimeout(r, 800)); continue; }
    throw err;
  }
  throw new XfinError("XFIN_AGGREGATOR_ERROR", 502, true);
}

/* ---------- Endpoints ---------- */
export interface XfinMe { status?: string; rootCode?: string; limits?: unknown; paymentTaxPercent?: number; paymentFeeOwner?: string }
export const getMe = () => request<XfinMe>("GET", "/me");

export type XfinConfigCheck =
  | { ready: false; code: "XFIN_NOT_CONFIGURED" | "XFIN_APP_INACTIVE" | "XFIN_FEE_OWNER_MISMATCH" | "XFIN_WEBHOOK_SECRET_MISSING" | string }
  | { ready: true };

/** Règle Allo Taxi : frais supportés par le chauffeur ⇒ paymentFeeOwner = CUSTOMER, sinon PAID interdit. */
export function evaluateMe(me: XfinMe, webhookSecretPresent: boolean, env: XfinEnvironment = "PRODUCTION"): XfinConfigCheck {
  if ((me.status ?? "").toLowerCase() !== "active") return { ready: false, code: "XFIN_APP_INACTIVE" };
  if ((me.paymentFeeOwner ?? "").toUpperCase() !== "CUSTOMER") return { ready: false, code: "XFIN_FEE_OWNER_MISMATCH" };
  // Sandbox : aucun webhook émis par xFin, suivi par polling serveur uniquement.
  if (env === "PRODUCTION" && !webhookSecretPresent) return { ready: false, code: "XFIN_WEBHOOK_SECRET_MISSING" };
  return { ready: true };
}

export const getOperators = (country = "GA") => request<unknown>("GET", "/operators", { query: { country } });

export interface XfinFees { operationFee?: { amount?: number }; feeOwner?: string; totalAmountIfChargedToCustomer?: number }
export function getFees(operatorCode: XfinOperator, amount = DAY_TICKET_AMOUNT_FCFA) {
  return request<XfinFees>("GET", "/fees", { query: { operatorCode, amount: String(amount), transactionType: "PAYMENT" } });
}
/** La réponse xFin fait foi ; aucun pourcentage supposé. */
export function parseFees(f: XfinFees) {
  const fee = f.operationFee?.amount;
  if (typeof fee !== "number" || fee < 0) throw new XfinError("XFIN_FEES_INVALID");
  return { providerFee: Math.round(fee), feeOwner: f.feeOwner ?? null, chargedToDriver: f.totalAmountIfChargedToCustomer ?? DAY_TICKET_AMOUNT_FCFA + Math.round(fee) };
}

/** Format local gabonais attendu par xFin (ex. 074123456). Règle explicite, testée. */
export function toXfinLocalPhone(input: string): string {
  const d = input.replace(/[\s.-]/g, "").replace(/^\+?241/, "");
  if (!/^0?\d{8}$/.test(d)) throw new XfinError("XFIN_PHONE_INVALID");
  return d.length === 8 ? `0${d}` : d;
}

export const buildAppTransactionRef = (paymentTransactionId: string) => `AT-PASS-${paymentTransactionId}`;

export interface XfinCreatePaymentResponse { success?: boolean; xfinReference?: string; status?: string; message?: string }
/** 201 ≠ encaissé : le résultat est toujours PENDING côté Allo Taxi. */
export async function createPayment(input: { operatorCode: XfinOperator; buyerPhone: string; appTransactionRef: string }) {
  const res = await request<XfinCreatePaymentResponse>("POST", "/payments", {
    body: { operatorCode: input.operatorCode, buyerPhoneNumber: toXfinLocalPhone(input.buyerPhone), amount: DAY_TICKET_AMOUNT_FCFA, appTransactionRef: input.appTransactionRef, freeInfo: "Ticket journalier Allo Taxi" },
  });
  return parseCreatePayment(res);
}
export function parseCreatePayment(res: XfinCreatePaymentResponse) {
  if (!res.xfinReference) throw new XfinError("XFIN_REFERENCE_MISSING");
  return { xfinReference: res.xfinReference, status: "PENDING" as const };
}

export interface XfinTransaction { xfinReference?: string; transactionType?: string; status?: string; failureReason?: string; errorCode?: string; reason?: string; amount?: number; fees?: number; netAmount?: number; completedAt?: string }
export const getTransaction = (xfinReference: string) => request<XfinTransaction>("GET", `/transactions/${encodeURIComponent(xfinReference)}`);
export const getBalance = () => request<unknown>("GET", "/balance");

/** Préparé mais volontairement NOT_CONFIGURED : aucun PIN, aucune interface de remboursement. */
export function giveChange(): Promise<never> { return Promise.reject(new XfinNotConfiguredError()); }
// POST /v1/split-payment volontairement NON implémenté : parts Associés calculées en interne.

/* ---------- Webhook ---------- */
export function verifyXfinSignature(rawBody: string, signature: string | null, secret: string | undefined): boolean {
  if (!secret || !signature) return false;
  const expected = createHmac("sha256", secret).update(rawBody, "utf8").digest("hex");
  const a = Buffer.from(signature.trim().toLowerCase(), "utf8");
  const b = Buffer.from(expected, "utf8");
  return a.length === b.length && timingSafeEqual(a, b);
}
export const webhookSecret = () => readEnv().webhookSecret;

export interface XfinWebhookPayload { event?: string; xfinReference?: string; appTransactionRef?: string; transactionType?: string; status?: string; amount?: number; fees?: number; netAmount?: number; completedAt?: string }
export function parseWebhook(p: XfinWebhookPayload) {
  if (p.event !== "TRANSACTION_UPDATED" || typeof p.xfinReference !== "string" || !p.xfinReference) return null;
  return toResolution(p, "webhook");
}

export function toResolution(t: XfinTransaction, source: "webhook" | "polling") {
  const int = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? Math.round(v) : null);
  return {
    _xfin_reference: t.xfinReference!,
    _status: mapProviderStatus(t.status),
    _transaction_type: t.transactionType ?? "PAYMENT",
    _amount: int(t.amount),
    _fees: int(t.fees),
    _net_amount: int(t.netAmount),
    _completed_at: t.completedAt ?? null,
    _source: source,
  };
}

/** Polling serveur : ne jamais faire confiance au navigateur ; un timeout d'écran ne rend pas FAILED. */
export async function refreshTransaction(xfinReference: string) {
  const t = await getTransaction(xfinReference);
  return toResolution({ ...t, xfinReference }, "polling");
}

/** Motif d'échec renvoyé par xFin (INSUFFICIENT_FUNDS, USER_REJECTED, TIMEOUT, INVALID_ACCOUNT…), normalisé. */
export function failureReasonOf(t: XfinTransaction): string | null {
  const r = t.failureReason ?? t.errorCode ?? t.reason;
  if (typeof r !== "string") return null;
  const v = r.toUpperCase().replace(/[^A-Z_]/g, "_").slice(0, 64);
  return v || null;
}
