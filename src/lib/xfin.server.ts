// Adaptateur serveur xFin (LOT 3A).
// Aucune documentation, aucun endpoint, aucun secret xFin n'est disponible à ce jour :
// cet adaptateur reste volontairement NOT_CONFIGURED. Aucune URL, aucun payload,
// aucune signature, aucun statut n'est inventé. Le mode PAID est verrouillé en base
// par public.xfin_integration_ready() = false.

export type XfinPaymentStatus = "pending" | "success" | "failed" | "canceled";

export interface XfinInitiateInput {
  internalReference: string;
  ticketAmountFcfa: number;
  /** Numéro de paiement explicitement fourni pour cette transaction ; jamais l'identité du chauffeur. */
  payerMsisdn: string;
}

export interface XfinInitiateResult {
  providerReference: string;
  feesFcfa: number;
  status: XfinPaymentStatus;
}

export interface XfinAdapter {
  readonly configured: boolean;
  initiatePayment(input: XfinInitiateInput): Promise<XfinInitiateResult>;
  getPaymentStatus(providerReference: string): Promise<XfinPaymentStatus>;
}

export class XfinNotConfiguredError extends Error {
  readonly code = "XFIN_NOT_CONFIGURED";
  constructor() {
    super("XFIN_NOT_CONFIGURED");
  }
}

const notConfigured: XfinAdapter = {
  configured: false,
  initiatePayment: () => Promise.reject(new XfinNotConfiguredError()),
  getPaymentStatus: () => Promise.reject(new XfinNotConfiguredError()),
};

/** Fail closed : renvoie toujours l'adaptateur non configuré tant qu'une intégration réelle n'est pas livrée. */
export function getXfinAdapter(): XfinAdapter {
  return notConfigured;
}
