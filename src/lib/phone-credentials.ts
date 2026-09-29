import { z } from "zod";

/** Gabon mobile number: 8 or 9 local digits after +241. */
export const phoneSchema = z
  .string()
  .transform((v) => v.replace(/\D/g, "").replace(/^241/, ""))
  .pipe(z.string().regex(/^0?\d{7,8}$/, "Numéro gabonais invalide."));

export const pinSchema = z.string().regex(/^\d{4}$|^\d{6}$/, "Le code PIN doit contenir 4 ou 6 chiffres.");

/** Deterministic internal identifier + password derived from phone + PIN (no email is ever sent). */
export function toCredentials(phone: string, pin: string) {
  const local = phoneSchema.parse(phone);
  return { email: `241${local}@tel.allotaxi.app`, password: `AT#${pin}#pin`, phone: `+241${local}` };
}
