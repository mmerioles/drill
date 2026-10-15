// The chime when a phase ends.

let audio = null;

/** Safari only lets sound start from a click, so the start button makes or
 *  wakes the audio, ready for when the phase ends. */
export function wakeAudio() {
  try {
    audio ??= new (window.AudioContext || window.webkitAudioContext)();
    if (audio.state === "suspended") audio.resume().catch(() => {});
  } catch {}
  return audio;
}

export function chime(focusDone) {
  const ctx = wakeAudio();
  if (!ctx) return;
  try {
    const notes = focusDone ? [880, 1318.5] : [659.3];
    notes.forEach((freq, i) => {
      const t = ctx.currentTime + i * 0.16;
      const osc = ctx.createOscillator(), gain = ctx.createGain();
      osc.type = "sine";
      osc.frequency.value = freq;
      gain.gain.setValueAtTime(0.0001, t);
      gain.gain.exponentialRampToValueAtTime(0.18, t + 0.02);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.9);
      osc.connect(gain).connect(ctx.destination);
      osc.start(t);
      osc.stop(t + 1);
    });
  } catch {}
}
