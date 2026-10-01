// Analyse IA documentaire — serveur uniquement. Aucun secret, fichier ou lien signé ne quitte ce module.
export const DOCUMENT_AI_MODEL = "openai/gpt-6-astra";
const GATEWAY_URL = "https://ai.gateway.lovable.dev/v1/responses";

const nullableString = { type: ["string", "null"] };
const nullableBool = { type: ["boolean", "null"] };

const RESULT_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["document_type", "readable", "extracted_fields", "field_confidences", "overall_confidence", "inconsistencies", "warnings", "recommended_decision"],
  properties: {
    document_type: { type: "string" },
    readable: { type: "boolean" },
    extracted_fields: {
      type: "object",
      additionalProperties: false,
      required: ["full_name", "document_number", "expiry_date", "categories", "plate", "make_model", "registered_seats", "person_visible", "face_visible", "vehicle_visible", "quality_ok"],
      properties: {
        full_name: nullableString,
        document_number: nullableString,
        expiry_date: { type: ["string", "null"], description: "YYYY-MM-DD ou null si illisible" },
        categories: nullableString,
        plate: nullableString,
        make_model: nullableString,
        registered_seats: { type: ["integer", "null"] },
        person_visible: nullableBool,
        face_visible: nullableBool,
        vehicle_visible: nullableBool,
        quality_ok: nullableBool,
      },
    },
    field_confidences: {
      type: "array",
      items: { type: "object", additionalProperties: false, required: ["field", "confidence"], properties: { field: { type: "string" }, confidence: { type: "number" } } },
    },
    overall_confidence: { type: "number" },
    inconsistencies: { type: "array", items: { type: "string" } },
    warnings: { type: "array", items: { type: "string" } },
    recommended_decision: { type: "string", enum: ["AI_APPROVE", "MANUAL_REVIEW_REQUIRED"] },
  },
} as const;

const TYPE_RULES: Record<string, string> = {
  identity_document: "Pièce d'identité. Vérifie la lisibilité et qu'il s'agit d'un document d'identité plausible. Extrais full_name si lisible.",
  driver_photo: "Photo du chauffeur. Indique uniquement person_visible, face_visible (visage suffisamment visible) et quality_ok. AUCUNE identification ni comparaison biométrique.",
  driving_license: "Permis de conduire. Extrais full_name, document_number, expiry_date, categories si lisibles.",
  registration_card: "Carte grise. Extrais plate, make_model, registered_seats (nombre TOTAL de places homologuées, conducteur inclus).",
  insurance: "Attestation d'assurance. Extrais plate (ou véhicule) et expiry_date.",
  technical_inspection: "Visite technique. Extrais plate et expiry_date.",
  vehicle_photo: "Photo du véhicule. Indique vehicle_visible et quality_ok.",
  vehicle_plate_photo: "Photo de la plaque. Extrais plate.",
};

export type DocumentAiContext = {
  doc_type: string;
  mime_type: string | null;
  expires_on: string | null;
  vehicle_plate: string | null;
  vehicle_model: string | null;
  registered_seats: number | null;
};

export class DocumentAiError extends Error {
  constructor(public code: string) { super(code); }
}

export async function analyzeDocumentWithAi(ctx: DocumentAiContext, file: Uint8Array, mime: string, apiKey: string) {
  const base64 = Buffer.from(file).toString("base64");
  const dataUrl = `data:${mime};base64,${base64}`;
  const filePart = mime === "application/pdf"
    ? { type: "input_file", filename: "document.pdf", file_data: dataUrl }
    : { type: "input_image", image_url: dataUrl, detail: "high" };

  const instructions = [
    "Tu es un contrôleur documentaire pour une plateforme VTC au Gabon. Tu produis un diagnostic structuré, jamais une décision définitive.",
    `Type attendu : ${ctx.doc_type}. ${TYPE_RULES[ctx.doc_type] ?? ""}`,
    "Règles absolues : n'invente jamais un caractère illisible ; toute valeur illisible ou absente vaut null. Les champs non pertinents pour ce type valent null.",
    "document_type = le type attendu si le document y correspond, sinon décris le type observé.",
    `Données déclarées à comparer : plaque=${ctx.vehicle_plate ?? "inconnue"}, modèle=${ctx.vehicle_model ?? "inconnu"}, places homologuées=${ctx.registered_seats ?? "inconnu"}, échéance déclarée=${ctx.expires_on ?? "aucune"}.`,
    "Toute différence avec ces données va dans inconsistencies. Tout doute (flou, reflet, recadrage, date partielle) va dans warnings.",
    "recommended_decision = AI_APPROVE uniquement si tout est lisible, cohérent et sans doute ; sinon MANUAL_REVIEW_REQUIRED. Le rejet n'existe pas.",
    "overall_confidence entre 0 et 1 ; sois conservateur.",
  ].join("\n");

  const response = await fetch(GATEWAY_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Lovable-API-Key": apiKey, "X-Lovable-AIG-SDK": "fetch" },
    body: JSON.stringify({
      model: DOCUMENT_AI_MODEL,
      stream: true,
      store: false,
      reasoning: { effort: "medium", summary: "auto" },
      include: ["reasoning.encrypted_content"],
      instructions,
      input: [{ role: "user", content: [{ type: "input_text", text: "Analyse ce document et retourne le résultat structuré." }, filePart] }],
      text: { format: { type: "json_schema", name: "document_check", strict: true, schema: RESULT_SCHEMA } },
    }),
  });
  if (!response.ok || !response.body) {
    console.error("document-ai gateway status", response.status);
    throw new DocumentAiError(`GATEWAY_${response.status}`);
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let text = "";
  let failure: string | null = null;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let idx: number;
    while ((idx = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, idx).trim();
      buffer = buffer.slice(idx + 1);
      if (!line.startsWith("data:")) continue;
      const payload = line.slice(5).trim();
      if (!payload || payload === "[DONE]") continue;
      try {
        const evt = JSON.parse(payload) as { type?: string; delta?: string; response?: { error?: { code?: string } } };
        if (evt.type === "response.output_text.delta" && typeof evt.delta === "string") text += evt.delta;
        if (evt.type === "response.failed" || evt.type === "error") failure = evt.response?.error?.code ?? "STREAM_FAILED";
        if (evt.type === "response.refusal.delta") failure = "REFUSED";
      } catch { /* ligne partielle ignorée */ }
    }
  }
  if (failure) throw new DocumentAiError(failure);
  if (!text.trim()) throw new DocumentAiError("EMPTY_OUTPUT");
  try {
    return JSON.parse(text) as Record<string, unknown>;
  } catch {
    throw new DocumentAiError("INVALID_OUTPUT");
  }
}
