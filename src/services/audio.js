let context;
let muted = false;

function audioContext() {
  if (!context) context = new (window.AudioContext || window.webkitAudioContext)();
  if (context.state === "suspended") context.resume();
  return context;
}

function tone(frequency, duration = 0.12, type = "square", volume = 0.035, delay = 0) {
  if (muted) return;
  const ctx = audioContext(), oscillator = ctx.createOscillator(), gain = ctx.createGain(), start = ctx.currentTime + delay;
  oscillator.type = type;
  oscillator.frequency.setValueAtTime(frequency, start);
  gain.gain.setValueAtTime(0.0001, start);
  gain.gain.exponentialRampToValueAtTime(volume, start + 0.012);
  gain.gain.exponentialRampToValueAtTime(0.0001, start + duration);
  oscillator.connect(gain).connect(ctx.destination);
  oscillator.start(start);
  oscillator.stop(start + duration + 0.02);
}

export function unlockAudio() {
  try { audioContext(); } catch { /* navegador sem Web Audio */ }
}

export function playDiceRoll() {
  if (muted) return;
  const ctx = audioContext(), length = Math.floor(ctx.sampleRate * 0.72), buffer = ctx.createBuffer(1, length, ctx.sampleRate), data = buffer.getChannelData(0);
  for (let index = 0; index < length; index += 1) data[index] = (Math.random() * 2 - 1) * (1 - index / length);
  const source = ctx.createBufferSource(), filter = ctx.createBiquadFilter(), gain = ctx.createGain();
  filter.type = "bandpass"; filter.frequency.value = 750; filter.Q.value = 1.1; gain.gain.value = 0.045;
  source.buffer = buffer; source.connect(filter).connect(gain).connect(ctx.destination); source.start();
  [0, .13, .26, .4, .54].forEach((delay, index) => tone(150 + index * 24, .055, "square", .025, delay));
}

export function playDiceResult(result) {
  const value = Math.max(1, Math.min(20, Number(result) || 1));
  const intensity = (value - 1) / 19;
  const volume = 0.012 + intensity * 0.052;
  const duration = 0.08 + intensity * 0.24;
  tone(190 + value * 15, duration, intensity > .65 ? "sawtooth" : "triangle", volume);
  if (value >= 6) tone(300 + value * 17, duration * .9, "square", volume * .62, .07);
  if (value >= 12) tone(105 + value * 4, duration * 1.4, "sawtooth", volume * .72, .02);
  if (value >= 17) tone(520 + value * 20, duration * 1.2, "triangle", volume * .75, .15);
  if (value === 20) {
    tone(880, .42, "square", .055, .2);
    tone(1320, .48, "triangle", .045, .28);
  }
}

export function playGiftTick() { tone(420 + Math.random() * 220, .045, "square", .018); }

export function playGiftReveal(type) {
  if (type === "lightning") {
    [760, 240, 110].forEach((frequency, index) => tone(frequency, .22, "sawtooth", .045, index * .07));
  } else if (type === "banana") {
    [520, 420, 310].forEach((frequency, index) => tone(frequency, .13, "square", .038, index * .1));
  } else if (type === "shell") {
    [180, 260, 360].forEach((frequency, index) => tone(frequency, .16, "sawtooth", .04, index * .08));
  } else {
    [300, 450, 680, 900].forEach((frequency, index) => tone(frequency, .2, "triangle", .04, index * .08));
  }
}

export function playVictory() {
  [392, 523, 659, 784, 1046].forEach((frequency, index) => tone(frequency, .28, "square", .035, index * .11));
}

export function playChatBubble() {
  tone(620, .08, "sine", .018);
  tone(840, .11, "sine", .015, .065);
}

export function toggleAudio() {
  muted = !muted;
  if (!muted) unlockAudio();
  return muted;
}

document.addEventListener("pointerdown", unlockAudio, { once: true });
