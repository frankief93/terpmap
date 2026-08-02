# Pocket Film 📷

A free, private, film-look pro camera that runs entirely in your browser. Every feature unlocked — no subscriptions, no in-app purchases, no accounts.

**We collect nothing. We store nothing. We share nothing.** All photo processing happens on your device.

## Features (all free)

- **8 film looks** — Natural, Gold 200, Meadow, Chrome, Dusk, Cinema, Mono 400, Noir
- **Pro dials** — exposure, contrast, color, warmth, fade, grain, halation, vignette
- **Real film processing at capture** — filmic tone curve with highlight shoulder, white balance, shadow color casts, luminance-weighted grain, halation glow, vignette (not just a CSS filter)
- **Front/back camera**, rule-of-thirds grid, photo review, save/share via the native share sheet
- **Installable PWA** — works offline once added to your home screen

## Use it on your iPhone

1. Host this folder anywhere with HTTPS — easiest option: enable **GitHub Pages** for this repo (Settings → Pages → deploy from branch), since it's all static files.
2. Open the URL in Safari.
3. Tap **Share → Add to Home Screen**. It now launches full-screen like a native app and works offline.

> Cameras require HTTPS — the app won't get camera access over plain `http://` (localhost excepted).

## Run locally

```sh
python3 -m http.server 8000
# open http://localhost:8000
```

## Stack

Zero dependencies, zero build step: plain HTML, CSS, and JavaScript, plus a service worker for offline support.
