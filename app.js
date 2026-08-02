/* Pocket Film — free, private, film-look pro camera.
 * All processing happens on-device. Nothing is collected, stored, or shared. */

(() => {
  "use strict";

  // ---------------------------------------------------------------------------
  // Film looks. Each look is a set of processing parameters applied at capture
  // (real pixel processing) and approximated live via CSS filters.
  // Params: ev (stops), contrast (-1..1), sat (0..2), warmth (-1..1),
  // tint (-1..1, green<->magenta), fade (0..1 lifted blacks), grain (0..1),
  // vignette (0..1), halation (0..1), bw (boolean), shadowTint [r,g,b] subtle.
  // ---------------------------------------------------------------------------
  const LOOKS = [
    { id: "natural",  name: "Natural",  ev: 0,    contrast: 0.06, sat: 1.02, warmth: 0.03,  tint: 0,     fade: 0.02, grain: 0.10, vignette: 0.15, halation: 0.05, bw: false, shadowTint: [0,0,0] },
    { id: "gold",     name: "Gold 200", ev: 0.1,  contrast: 0.12, sat: 1.12, warmth: 0.22,  tint: 0.02,  fade: 0.06, grain: 0.22, vignette: 0.25, halation: 0.25, bw: false, shadowTint: [8,4,0] },
    { id: "meadow",   name: "Meadow",   ev: 0.05, contrast: 0.02, sat: 0.92, warmth: 0.10,  tint: -0.06, fade: 0.12, grain: 0.16, vignette: 0.18, halation: 0.12, bw: false, shadowTint: [0,6,4] },
    { id: "chrome",   name: "Chrome",   ev: -0.05,contrast: 0.22, sat: 1.18, warmth: -0.04, tint: 0.03,  fade: 0.00, grain: 0.12, vignette: 0.30, halation: 0.10, bw: false, shadowTint: [0,2,8] },
    { id: "dusk",     name: "Dusk",     ev: -0.1, contrast: 0.10, sat: 0.85, warmth: -0.12, tint: 0.05,  fade: 0.10, grain: 0.18, vignette: 0.35, halation: 0.18, bw: false, shadowTint: [4,0,10] },
    { id: "cinema",   name: "Cinema",   ev: -0.05,contrast: 0.18, sat: 0.88, warmth: 0.08,  tint: -0.04, fade: 0.08, grain: 0.14, vignette: 0.40, halation: 0.30, bw: false, shadowTint: [0,5,8] },
    { id: "mono",     name: "Mono 400", ev: 0,    contrast: 0.20, sat: 0,    warmth: 0,     tint: 0,     fade: 0.05, grain: 0.30, vignette: 0.30, halation: 0.08, bw: true,  shadowTint: [0,0,0] },
    { id: "noir",     name: "Noir",     ev: -0.15,contrast: 0.38, sat: 0,    warmth: 0,     tint: 0,     fade: 0.00, grain: 0.20, vignette: 0.50, halation: 0.05, bw: true,  shadowTint: [0,0,0] },
  ];

  // Pro dials the user can override on top of the selected look.
  const DIALS = [
    { key: "ev",       label: "Exposure", min: -1.5, max: 1.5, step: 0.05, fmt: v => (v > 0 ? "+" : "") + v.toFixed(2) },
    { key: "contrast", label: "Contrast", min: -0.5, max: 0.6, step: 0.02, fmt: v => Math.round(v * 100) + "" },
    { key: "sat",      label: "Color",    min: 0,    max: 2,   step: 0.02, fmt: v => Math.round(v * 100) + "%" },
    { key: "warmth",   label: "Warmth",   min: -0.5, max: 0.5, step: 0.02, fmt: v => Math.round(v * 100) + "" },
    { key: "fade",     label: "Fade",     min: 0,    max: 0.4, step: 0.02, fmt: v => Math.round(v * 250) + "" },
    { key: "grain",    label: "Grain",    min: 0,    max: 1,   step: 0.02, fmt: v => Math.round(v * 100) + "" },
    { key: "halation", label: "Halation", min: 0,    max: 1,   step: 0.02, fmt: v => Math.round(v * 100) + "" },
    { key: "vignette", label: "Vignette", min: 0,    max: 1,   step: 0.02, fmt: v => Math.round(v * 100) + "" },
  ];

  const MAX_EDGE = 2560; // capture resolution cap keeps processing fast

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  const state = {
    look: LOOKS[0],
    overrides: {},          // dial overrides on top of the look
    facing: "environment",
    stream: null,
    lastPhotoURL: null,
    lastPhotoBlob: null,
  };

  const effective = () => ({ ...state.look, ...state.overrides });

  // ---------------------------------------------------------------------------
  // DOM
  // ---------------------------------------------------------------------------
  const $ = id => document.getElementById(id);
  const video = $("video");
  const looksEl = $("looks");
  const dialRow = $("dial-row");
  const lookName = $("look-name");
  const grainOverlay = $("grain-overlay");
  const vignetteOverlay = $("vignette-overlay");

  // ---------------------------------------------------------------------------
  // Camera
  // ---------------------------------------------------------------------------
  async function startCamera() {
    stopCamera();
    $("camera-error").classList.add("hidden");
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: {
          facingMode: state.facing,
          width: { ideal: 4032 },
          height: { ideal: 3024 },
        },
        audio: false,
      });
      state.stream = stream;
      video.srcObject = stream;
      video.classList.toggle("mirrored", state.facing === "user");
      await video.play().catch(() => {});
    } catch (err) {
      const msg = location.protocol === "http:" && location.hostname !== "localhost"
        ? "Cameras only work over HTTPS. Open this app from a secure (https://) address."
        : "Allow camera access in your browser settings, then try again. Nothing ever leaves your device.";
      $("camera-error-msg").textContent = msg;
      $("camera-error").classList.remove("hidden");
      console.warn("getUserMedia failed:", err);
    }
  }

  function stopCamera() {
    if (state.stream) {
      state.stream.getTracks().forEach(t => t.stop());
      state.stream = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Live preview approximation (CSS filters — the real look is baked at capture)
  // ---------------------------------------------------------------------------
  function updatePreview() {
    const p = effective();
    const brightness = Math.pow(2, p.ev * 0.7);
    const contrast = 1 + p.contrast * 0.85;
    const saturate = p.bw ? 0 : p.sat;
    const sepia = Math.max(0, p.warmth) * 0.45;
    const hue = p.warmth < 0 ? p.warmth * -18 : 0; // cool shift
    video.style.filter =
      `brightness(${brightness.toFixed(3)}) contrast(${contrast.toFixed(3)}) ` +
      `saturate(${saturate.toFixed(3)}) sepia(${sepia.toFixed(3)})` +
      (hue ? ` hue-rotate(${hue.toFixed(1)}deg)` : "");
    grainOverlay.style.opacity = (0.05 + p.grain * 0.22).toFixed(3);
    vignetteOverlay.style.opacity = (p.vignette * 0.9).toFixed(3);
    lookName.textContent = state.look.name;
  }

  // ---------------------------------------------------------------------------
  // Capture + real pixel processing
  // ---------------------------------------------------------------------------
  function capture() {
    if (!state.stream || !video.videoWidth) return;

    // Shutter feedback
    const flash = $("flash-overlay");
    flash.classList.add("firing");
    requestAnimationFrame(() => requestAnimationFrame(() => flash.classList.remove("firing")));
    if (navigator.vibrate) navigator.vibrate(15);

    const vw = video.videoWidth, vh = video.videoHeight;
    const scale = Math.min(1, MAX_EDGE / Math.max(vw, vh));
    const w = Math.round(vw * scale), h = Math.round(vh * scale);

    const canvas = document.createElement("canvas");
    canvas.width = w; canvas.height = h;
    const ctx = canvas.getContext("2d", { willReadFrequently: true });

    if (state.facing === "user") {
      ctx.translate(w, 0);
      ctx.scale(-1, 1);
    }
    ctx.drawImage(video, 0, 0, w, h);
    ctx.setTransform(1, 0, 0, 1, 0, 0);

    processFrame(ctx, w, h, effective());

    canvas.toBlob(blob => {
      if (!blob) return;
      if (state.lastPhotoURL) URL.revokeObjectURL(state.lastPhotoURL);
      state.lastPhotoBlob = blob;
      state.lastPhotoURL = URL.createObjectURL(blob);
      $("thumb-img").src = state.lastPhotoURL;
    }, "image/jpeg", 0.92);
  }

  function processFrame(ctx, w, h, p) {
    const img = ctx.getImageData(0, 0, w, h);
    const d = img.data;

    // Precompute tone curve LUT: exposure, film S-curve, fade (lifted blacks).
    const lut = new Uint8ClampedArray(256);
    const gain = Math.pow(2, p.ev);
    for (let i = 0; i < 256; i++) {
      let x = (i / 255) * gain;
      // Filmic S-curve blended in by contrast amount
      const s = x <= 0 ? 0 : x >= 1 ? 1 : x * x * (3 - 2 * x); // smoothstep
      const c = Math.max(0, Math.min(1, 0.5 + (x - 0.5) * (1 + p.contrast * 1.6)));
      x = x * 0.35 + s * 0.25 + c * 0.4;
      // Soft highlight shoulder
      x = x / (1 + Math.max(0, x - 0.9) * 0.6);
      // Fade: lift blacks toward gray
      x = p.fade * 0.18 + x * (1 - p.fade * 0.18);
      lut[i] = Math.max(0, Math.min(255, Math.round(x * 255)));
    }

    // White balance multipliers
    const wr = 1 + p.warmth * 0.22 + p.tint * 0.06;
    const wg = 1 - Math.abs(p.tint) * 0.05 + (p.tint < 0 ? -p.tint * 0.12 : 0);
    const wb = 1 - p.warmth * 0.22 + (p.tint > 0 ? p.tint * 0.12 : 0);

    const sat = p.bw ? 0 : p.sat;
    const [str, stg, stb] = p.shadowTint;
    const grainAmt = p.grain * 26;
    const vigAmt = p.vignette;
    const cx = w / 2, cy = h / 2;
    const maxDist = Math.sqrt(cx * cx + cy * cy);

    // Cheap deterministic-ish noise
    let seed = (Date.now() & 0xffff) | 1;
    const rand = () => {
      seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5;
      return ((seed >>> 0) / 4294967296) - 0.5;
    };

    for (let y = 0; y < h; y++) {
      // Vignette factor varies slowly; compute per row segment for speed
      const dy = y - cy;
      for (let x = 0; x < w; x++) {
        const i = (y * w + x) * 4;
        let r = lut[Math.min(255, Math.round(d[i] * wr))];
        let g = lut[Math.min(255, Math.round(d[i + 1] * wg))];
        let b = lut[Math.min(255, Math.round(d[i + 2] * wb))];

        // Saturation around luminance
        const lum = r * 0.299 + g * 0.587 + b * 0.114;
        r = lum + (r - lum) * sat;
        g = lum + (g - lum) * sat;
        b = lum + (b - lum) * sat;

        // Subtle shadow tint (film color cast in shadows)
        const shadowW = 1 - lum / 255;
        r += str * shadowW; g += stg * shadowW; b += stb * shadowW;

        // Grain: stronger in midtones, like real film
        if (grainAmt > 0) {
          const mid = 1 - Math.abs(lum - 128) / 128;
          const n = rand() * grainAmt * (0.35 + mid * 0.65);
          r += n; g += n; b += n;
        }

        // Vignette
        if (vigAmt > 0) {
          const dx = x - cx;
          const dist = Math.sqrt(dx * dx + dy * dy) / maxDist;
          const v = 1 - vigAmt * 0.55 * dist * dist * dist;
          r *= v; g *= v; b *= v;
        }

        d[i] = r; d[i + 1] = g; d[i + 2] = b;
      }
    }
    ctx.putImageData(img, 0, 0);

    // Halation: blurred highlight glow with a warm cast, screened on top.
    if (p.halation > 0.02 && "filter" in ctx) {
      try {
        const off = document.createElement("canvas");
        const ds = 4; // downscale for a soft, cheap blur
        off.width = Math.max(1, Math.round(w / ds));
        off.height = Math.max(1, Math.round(h / ds));
        const octx = off.getContext("2d");
        // Isolate highlights by crushing everything else
        octx.filter = "brightness(1.4) contrast(3) blur(3px)";
        octx.drawImage(ctx.canvas, 0, 0, off.width, off.height);
        ctx.save();
        ctx.globalCompositeOperation = "screen";
        ctx.globalAlpha = p.halation * 0.28;
        ctx.filter = `blur(${Math.round(6 + p.halation * 10)}px) sepia(0.5) saturate(1.4)`;
        ctx.drawImage(off, 0, 0, w, h);
        ctx.restore();
        ctx.filter = "none";
      } catch (e) { /* halation is a garnish; skip if unsupported */ }
    }
  }

  // ---------------------------------------------------------------------------
  // Save / share
  // ---------------------------------------------------------------------------
  async function saveOrShare() {
    if (!state.lastPhotoBlob) return;
    const file = new File([state.lastPhotoBlob], `pocketfilm-${Date.now()}.jpg`, { type: "image/jpeg" });
    if (navigator.canShare && navigator.canShare({ files: [file] })) {
      try {
        await navigator.share({ files: [file] });
        return;
      } catch (e) {
        if (e && e.name === "AbortError") return; // user cancelled
      }
    }
    // Fallback: download link
    const a = document.createElement("a");
    a.href = state.lastPhotoURL;
    a.download = file.name;
    document.body.appendChild(a);
    a.click();
    a.remove();
  }

  // ---------------------------------------------------------------------------
  // UI construction
  // ---------------------------------------------------------------------------
  function buildLooks() {
    looksEl.innerHTML = "";
    for (const look of LOOKS) {
      const b = document.createElement("button");
      b.className = "look-chip" + (look === state.look ? " selected" : "");
      b.textContent = look.name;
      b.setAttribute("role", "tab");
      b.addEventListener("click", () => {
        state.look = look;
        state.overrides = {}; // picking a look resets manual tweaks
        buildLooks();
        buildDials();
        updatePreview();
      });
      looksEl.appendChild(b);
    }
  }

  function buildDials() {
    dialRow.innerHTML = "";
    const p = effective();
    for (const dial of DIALS) {
      const wrap = document.createElement("div");
      wrap.className = "dial";
      const label = document.createElement("label");
      label.textContent = dial.label;
      const input = document.createElement("input");
      input.type = "range";
      input.min = dial.min; input.max = dial.max; input.step = dial.step;
      input.value = p[dial.key];
      const out = document.createElement("output");
      out.textContent = dial.fmt(p[dial.key]);
      input.addEventListener("input", () => {
        state.overrides[dial.key] = parseFloat(input.value);
        out.textContent = dial.fmt(parseFloat(input.value));
        updatePreview();
      });
      wrap.append(label, input, out);
      dialRow.appendChild(wrap);
    }
  }

  // ---------------------------------------------------------------------------
  // Wiring
  // ---------------------------------------------------------------------------
  $("btn-shutter").addEventListener("click", capture);
  $("btn-retry").addEventListener("click", startCamera);

  $("btn-flip").addEventListener("click", () => {
    state.facing = state.facing === "environment" ? "user" : "environment";
    startCamera();
  });

  $("btn-pro").addEventListener("click", () => {
    const panel = $("pro-panel");
    const showing = panel.classList.toggle("hidden");
    $("btn-pro").classList.toggle("active", !showing);
    if (!showing) buildDials();
  });

  $("btn-grid").addEventListener("click", () => {
    const g = $("grid-overlay");
    g.classList.toggle("hidden");
    $("btn-grid").classList.toggle("active", !g.classList.contains("hidden"));
  });

  $("btn-thumb").addEventListener("click", () => {
    if (!state.lastPhotoURL) return;
    $("review-img").src = state.lastPhotoURL;
    $("review").classList.remove("hidden");
  });
  $("btn-review-close").addEventListener("click", () => $("review").classList.add("hidden"));
  $("btn-review-delete").addEventListener("click", () => {
    if (state.lastPhotoURL) URL.revokeObjectURL(state.lastPhotoURL);
    state.lastPhotoURL = null;
    state.lastPhotoBlob = null;
    $("thumb-img").removeAttribute("src");
    $("review").classList.add("hidden");
  });
  $("btn-save").addEventListener("click", saveOrShare);

  $("btn-settings").addEventListener("click", () => $("about").classList.remove("hidden"));
  $("btn-about-close").addEventListener("click", () => $("about").classList.add("hidden"));

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) stopCamera();
    else startCamera();
  });

  // ---------------------------------------------------------------------------
  // Boot
  // ---------------------------------------------------------------------------
  buildLooks();
  buildDials();
  updatePreview();
  startCamera();

  if ("serviceWorker" in navigator && location.protocol === "https:") {
    navigator.serviceWorker.register("sw.js").catch(() => {});
  }
})();
