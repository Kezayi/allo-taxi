// Carillon synthétisé (Web Audio) : aucun fichier à télécharger, fonctionne hors ligne.
let ctx: AudioContext | null = null;

function getContext() {
  if (typeof window === "undefined") return null;
  const Ctor = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
  if (!Ctor) return null;
  ctx ??= new Ctor();
  if (ctx.state === "suspended") void ctx.resume();
  return ctx;
}

// Déverrouille l'audio au premier geste (exigence des navigateurs mobiles)
if (typeof window !== "undefined") {
  const unlock = () => { getContext(); window.removeEventListener("pointerdown", unlock); window.removeEventListener("keydown", unlock); };
  window.addEventListener("pointerdown", unlock);
  window.addEventListener("keydown", unlock);
}

export function playChime(notes: number[] = [1318.5, 1046.5, 784]) {
  const audio = getContext();
  if (!audio) return;
  const start = audio.currentTime + 0.02;
  notes.forEach((freq, i) => {
    const t = start + i * 0.28;
    [1, 2.76].forEach((harmonic, h) => {
      const osc = audio.createOscillator();
      const gain = audio.createGain();
      osc.type = "sine";
      osc.frequency.value = freq * harmonic;
      const peak = h === 0 ? 0.28 : 0.06;
      gain.gain.setValueAtTime(0.0001, t);
      gain.gain.exponentialRampToValueAtTime(peak, t + 0.01);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + 1.6);
      osc.connect(gain).connect(audio.destination);
      osc.start(t);
      osc.stop(t + 1.7);
    });
  });
  if ("vibrate" in navigator) navigator.vibrate?.([120, 80, 120]);
}

export const chimes = {
  newRide: () => playChime([1046.5, 1318.5]),
  arrived: () => playChime([784, 1046.5, 1318.5, 1568]),
  accepted: () => playChime([1318.5, 1046.5, 784]),
  finished: () => playChime([1568, 1318.5, 1046.5, 784]),
};
