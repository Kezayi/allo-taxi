import { z } from "zod";

import { supabase } from "@/integrations/supabase/client";

/** Gabon mobile number: 8 or 9 local digits after +241 (e.g. 074 57 54 94). */
export const phoneSchema = z
  .string()
  .transform((v) => v.replace(/\D/g, "").replace(/^241/, ""))
  .pipe(z.string().regex(/^0?\d{7,8}$/, "Numéro gabonais invalide."));

export const pinSchema = z.string().regex(/^\d{4}$|^\d{6}$/, "Le code PIN doit contenir 4 ou 6 chiffres.");

/**
 * Accounts are identified only by phone + PIN. Auth needs an internal identifier and
 * a password of at least 6 chars, so both are derived deterministically; no email is
 * ever sent (email confirmation is disabled) and the PIN is hashed by the auth service.
 */
function toCredentials(phone: string, pin: string) {
  const local = phoneSchema.parse(phone);
  return { email: `241${local}@tel.allotaxi.app`, password: `AT#${pin}#pin`, phone: `+241${local}` };
}

export async function signInWithPhonePin(phone: string, pin: string) {
  const { email, password } = toCredentials(phone, pin);
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw new Error("Numéro ou code PIN incorrect.");
}

export async function signUpWithPhonePin(phone: string, pin: string, firstName?: string) {
  const creds = toCredentials(phone, pin);
  const { data, error } = await supabase.auth.signUp({ email: creds.email, password: creds.password, options: { data: { phone: creds.phone } } });
  if (error) throw new Error(error.message.includes("registered") ? "Ce numéro possède déjà un compte." : "Création du compte impossible.");
  if (!data.session) await signInWithPhonePin(phone, pin);
  const uid = data.user?.id;
  if (uid) await supabase.from("profiles").insert({ user_id: uid, phone: creds.phone, first_name: firstName ?? null });
}
