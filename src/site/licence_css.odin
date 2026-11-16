package tk_site

// The style of the shop's pages (licence_pages/*.html put it in their head as {{shop_css}}): the bar, the hero, the offer's
// card, its button, the facts and the questions before buying, the licence card and the help of the thank-you page, the
// legal pages' column, the foot.
//
// It brings no colour of its own: it reads the site's custom properties, so each program keeps its accent, and a site that
// switches them for a light theme switches these pages too. Two families are read, each with a fallback to the other and
// then to the system's colours (Canvas, CanvasText), which follow the page's color-scheme:
//
//   --text                 the text
//   --muted or --weak      the quieter text
//   --soft or --faint      the quietest text
//   --surface or --bg2     a card
//   --surface-2 or --bg3   inside a card (the key)
//   --line-2 or --line     the lines (a translucent grey, which reads on dark and on light, when neither is there)
//   --accent               the button, the check marks, the hero's glow; on the thank-you page also the logo's glow, the
//                          waiting dots, the card's tint, the help's tint and edge, the first hue of the confetti
//   --accent-ink           the text on the accent (near black when not set: a site whose light accent is dark sets it)
//
// A class name starts with shop-, so the site's own .btn, .card or footer never reach these pages. No remote font, no
// color-mix and no :has, as docs_css. A program that keeps its own pages puts LICENCE_CSS in its stylesheet.
LICENCE_CSS :: `.shop-page {
  --shop-text: var(--text, CanvasText);
  --shop-muted: var(--muted, var(--weak, GrayText));
  --shop-faint: var(--soft, var(--faint, GrayText));
  --shop-card: var(--surface, var(--bg2, Canvas));
  --shop-well: var(--surface-2, var(--bg3, Canvas));
  --shop-line: var(--line-2, var(--line, rgba(128, 128, 128, 0.28)));
  --shop-accent: var(--accent, LinkText);
  --shop-ink: var(--accent-ink, #15120e);
  color: var(--shop-text);
  overflow-x: hidden;
}
.shop-page main.shop a { color: var(--shop-accent); }
.shop-wrap { max-width: 880px; margin: 0 auto; padding: 0 20px; }

/* the bar: the program's icon and name, back to its home */
.shop-top { border-bottom: 1px solid var(--shop-line); }
.shop-top .shop-wrap { display: flex; align-items: center; justify-content: space-between; gap: 16px; min-height: 58px; }
.shop-brand { display: inline-flex; align-items: center; gap: 10px; font-weight: 700; font-size: 1.05rem; }
.shop-page .shop-brand { color: var(--shop-text); text-decoration: none; }
.shop-brand img { border-radius: 6px; }
.shop-page .shop-back { color: var(--shop-muted); font-size: 0.92rem; text-decoration: none; }
.shop-page .shop-back:hover { color: var(--shop-text); }

/* the main column: the site's own main rules (a width, a padding) give way to the shop's */
main.shop { max-width: none; margin: 0; padding: 0 0 56px; }

/* the hero: the icon, a quiet label, the program's name as it writes it, one line; a soft glow of the accent behind */
.shop-hero { position: relative; isolation: isolate; overflow: hidden; padding: 64px 20px 36px; text-align: center; }
.shop-hero::before {
  content: ""; position: absolute; z-index: -1; left: 50%; top: -140px; width: 560px; height: 380px; margin-left: -280px;
  border-radius: 50%; background: var(--shop-accent); opacity: 0.13; filter: blur(70px);
}
.shop-icon { display: block; margin: 0 auto 18px; }   /* (a program's logo is drawn on nothing: no frame, no shadow around it) */
.shop-eyebrow { margin: 0 0 4px; color: var(--shop-accent); font-size: 0.82rem; font-weight: 700; letter-spacing: 0.12em; text-transform: uppercase; }
.shop-name { margin: 0 0 12px; font-size: clamp(2.6rem, 10vw, 4.2rem); line-height: 1.02; letter-spacing: -0.03em; overflow-wrap: anywhere; }
.shop-thanks-title { margin: 0 0 12px; font-size: clamp(1.9rem, 6vw, 2.8rem); line-height: 1.1; letter-spacing: -0.02em; overflow-wrap: anywhere; }
.shop-lead { max-width: 560px; margin: 0 auto; color: var(--shop-muted); font-size: 1.08rem; line-height: 1.55; }

/* the offer: one card, the price large, what the licence gives, one button */
.shop-offer {
  position: relative; overflow: hidden; max-width: 440px; margin: 8px auto 0; padding: 30px 30px 24px;
  background: var(--shop-card); border: 1px solid var(--shop-line); border-radius: 18px;
  box-shadow: 0 24px 60px -24px rgba(0, 0, 0, 0.5); font-variant-numeric: tabular-nums;
}
.shop-offer-label { margin: 0 0 10px; color: var(--shop-muted); font-size: 0.82rem; font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase; }
.shop-price { display: flex; align-items: center; gap: 14px; margin: 0 0 6px; }
.shop-amount { font-size: 3.6rem; font-weight: 750; line-height: 1; letter-spacing: -0.04em; white-space: nowrap; }
.shop-once { color: var(--shop-muted); font-size: 0.9rem; line-height: 1.3; }
.shop-price-note { margin: 4px 0 0; color: var(--shop-muted); font-size: 0.92rem; }
.shop-gets { list-style: none; margin: 22px 0 24px; padding: 0; }
.shop-gets li { display: flex; align-items: flex-start; gap: 12px; margin: 0; padding: 7px 0; line-height: 1.45; }
.shop-check { flex: none; width: 20px; height: 20px; margin-top: 1px; color: var(--shop-accent); }
/* the "i" after a line of the offer: a small ring that leads to the question telling more */
.shop-page .shop-info {
  display: inline-flex; align-items: center; justify-content: center; width: 17px; height: 17px; margin-left: 6px;
  border: 1px solid var(--shop-line); border-radius: 50%; color: var(--shop-muted); font-size: 0.72rem; font-weight: 700;
  font-style: italic; line-height: 1; text-decoration: none; vertical-align: 1px;
}
.shop-page .shop-info:hover { border-color: var(--shop-accent); color: var(--shop-text); }

/* the button: the accent, full width; while the shop is closed, a dashed outline that says "Coming soon" */
.shop-buy, .shop-quiet {
  display: flex; align-items: center; justify-content: center; width: 100%; min-height: 50px; padding: 12px 20px;
  border: 1px solid transparent; border-radius: 12px; font: inherit; font-size: 1.05rem; font-weight: 700; cursor: pointer;
  transition: transform 0.12s, box-shadow 0.12s, filter 0.12s;
}
.shop-buy { background: var(--shop-accent); color: var(--shop-ink); box-shadow: 0 8px 24px -10px rgba(0, 0, 0, 0.55); }
.shop-buy:hover { filter: brightness(1.08); transform: translateY(-1px); box-shadow: 0 12px 30px -10px rgba(0, 0, 0, 0.6); }
.shop-buy:active { transform: translateY(1px); filter: brightness(0.96); }
.shop-buy:disabled, .shop-buy:disabled:hover {
  background: transparent; color: var(--shop-muted); border: 1px dashed var(--shop-line); box-shadow: none;
  filter: none; transform: none; cursor: default;
}
.shop-quiet { background: transparent; color: var(--shop-text); border-color: var(--shop-line); }
.shop-quiet:hover { border-color: var(--shop-accent); }
.shop-buy:focus-visible, .shop-quiet:focus-visible, .shop-key:focus-visible { outline: 2px solid var(--shop-accent); outline-offset: 3px; }
.shop-status { margin: 12px 0 0; color: var(--shop-text); font-size: 0.92rem; text-align: center; }
.shop-fine { margin: 14px 0 0; color: var(--shop-faint); font-size: 0.82rem; line-height: 1.5; }
.shop-offer .shop-fine { text-align: center; }

/* the sections under the offer: before you buy, the legal pages */
.shop-section { padding-top: 56px; }
.shop-h2, .shop-section h2 { margin: 0 0 16px; font-size: 1.5rem; letter-spacing: -0.01em; }
.shop-facts { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 0 36px; margin: 0; }
.shop-facts div { padding: 14px 0; border-top: 1px solid var(--shop-line); }
.shop-facts dt { font-weight: 700; font-size: 0.95rem; }
.shop-facts dd { margin: 3px 0 0; color: var(--shop-muted); font-size: 0.95rem; line-height: 1.55; }

/* the questions under the facts: one line each, the answer under it when opened */
.shop-faq details { border-top: 1px solid var(--shop-line); }
.shop-faq details:last-child { border-bottom: 1px solid var(--shop-line); }
.shop-faq summary { padding: 14px 0; font-weight: 700; cursor: pointer; }
.shop-faq summary:focus-visible { outline: 2px solid var(--shop-accent); outline-offset: 3px; }
.shop-faq details > div { padding: 0 0 14px; color: var(--shop-muted); line-height: 1.6; }
.shop-faq details > div p { margin: 0 0 8px; }

/* a legal page: one readable column */
.shop-doc { max-width: 720px; padding-top: 48px; line-height: 1.65; }
.shop-doc h1 { margin: 0 0 6px; font-size: clamp(2rem, 7vw, 2.6rem); letter-spacing: -0.02em; }
.shop-doc h2 { margin: 32px 0 8px; font-size: 1.2rem; }
.shop-doc > p, .shop-doc > ul { color: var(--shop-muted); }
.shop-doc > ul { padding-left: 20px; }
.shop-doc li { margin-bottom: 6px; }
.shop-doc strong { color: var(--shop-text); }
.shop-doc .shop-eyebrow { margin: 0 0 4px; }
.shop-doc .shop-fine { margin: 0 0 24px; }

/* the thank-you page: the logo floating in a glow of the accent, the status, the warm line, then the licence card.
   The gold (the key's edge, the stars, one hue of the confetti) is the same in every program: it says "a licence", not
   "this program"; everything else is the site's own colours. Without color-mix, a translucent accent is a pseudo-element
   filled with the accent and given an opacity. */
.shop-stage { position: relative; display: block; width: 104px; height: 104px; margin: 0 auto 18px; }
.shop-stage::before {
  content: ""; position: absolute; z-index: -1; inset: -26px; border-radius: 50%;
  background: radial-gradient(closest-side, var(--shop-accent), transparent); opacity: 0.24;
}
.shop-logo { display: block; width: 104px; height: 104px; max-width: none; animation: shop-bob 3.6s ease-in-out infinite; }
.shop-thanks { max-width: 680px; margin: 0 auto; padding: 0 20px; }
.shop-wait { display: flex; align-items: center; justify-content: center; gap: 4px; margin: -12px 0 14px; color: var(--shop-muted); text-align: center; }
.shop-thanks[data-state="failed"] .shop-wait { color: var(--shop-text); text-align: left; }
/* three dots that breathe while the Worker makes the licence, gone once the script has an answer */
.shop-dots { display: inline-flex; gap: 5px; margin-left: 6px; }
.shop-thanks:not([data-state="waiting"]) .shop-dots { display: none; }
.shop-dots i { width: 6px; height: 6px; border-radius: 50%; background: var(--shop-accent); opacity: 0.25; animation: shop-dot 1.2s infinite; }
.shop-dots i:nth-child(2) { animation-delay: 0.2s; }
.shop-dots i:nth-child(3) { animation-delay: 0.4s; }
.shop-warm { max-width: 560px; margin: 0 auto 26px; color: var(--shop-muted); line-height: 1.55; text-align: center; text-wrap: balance; }
.shop-card {
  position: relative; isolation: isolate; overflow: hidden; padding: 26px; background: var(--shop-card); border: 1px solid var(--shop-line);
  border-radius: 18px; box-shadow: 0 24px 60px -24px rgba(0, 0, 0, 0.5);
}
/* (z-index -1 inside the isolated card: above its background, under its text) */
.shop-thanks .shop-card::before {
  content: ""; position: absolute; z-index: -1; inset: 0; pointer-events: none;
  background: linear-gradient(160deg, var(--shop-accent) 0%, transparent 62%); opacity: 0.1;
}
/* the sheen: a band of light that crosses the card once, when the licence arrives */
.shop-thanks .shop-card::after {
  content: ""; position: absolute; inset: 0; pointer-events: none; transform: translateX(-120%);
  background: linear-gradient(115deg, transparent 35%, rgba(255, 255, 255, 0.13) 50%, transparent 65%);
}
.shop-thanks[data-state="ready"] .shop-card { animation: shop-rise 0.7s cubic-bezier(0.2, 0.8, 0.2, 1) both; }
.shop-thanks[data-state="ready"] .shop-card::after { animation: shop-sheen 1.6s 0.5s ease-out 1 both; }
/* six gold stars that twinkle in turn at the card's corners */
.shop-spark {
  position: absolute; width: 14px; height: 14px; pointer-events: none; opacity: 0;
  background: #f6d98b; filter: drop-shadow(0 0 4px rgba(255, 210, 120, 0.85));
  clip-path: polygon(50% 0, 60% 40%, 100% 50%, 60% 60%, 50% 100%, 40% 60%, 0 50%, 40% 40%);
  animation: shop-twinkle 3.4s ease-in-out infinite;
}
.shop-spark:nth-of-type(1) { top: 14px; right: 36px; }
.shop-spark:nth-of-type(2) { top: 52px; right: 12px; width: 9px; height: 9px; animation-delay: 1.3s; }
.shop-spark:nth-of-type(3) { top: 118px; left: 10px; width: 10px; height: 10px; animation-delay: 2.1s; }
.shop-spark:nth-of-type(4) { top: 214px; right: 52px; width: 11px; height: 11px; animation-delay: 0.7s; }
.shop-spark:nth-of-type(5) { top: 252px; left: 40px; width: 12px; height: 12px; animation-delay: 1.8s; }
.shop-spark:nth-of-type(6) { bottom: 16px; right: 22px; width: 16px; height: 16px; animation-delay: 2.6s; }
/* the confetti: a fixed layer over the page, one burst; the hues cycle with the pieces, the first is the program's */
.shop-confetti { position: fixed; inset: 0; z-index: 50; overflow: hidden; pointer-events: none; }
.shop-confetti b {
  position: absolute; top: -14px; width: 8px; height: 14px; border-radius: 2px; opacity: 0;
  animation: shop-fall var(--t, 3s) var(--d, 0s) cubic-bezier(0.25, 0.35, 0.55, 1) both;
}
.shop-confetti b:nth-child(6n + 1) { background: var(--shop-accent); }
.shop-confetti b:nth-child(6n + 2) { background: #ffcf5c; }
.shop-confetti b:nth-child(6n + 3) { background: #ffffff; }
.shop-confetti b:nth-child(6n + 4) { background: #7bd88f; }
.shop-confetti b:nth-child(6n + 5) { background: #ff8fa3; }
.shop-confetti b:nth-child(6n + 6) { background: #b9a2ff; }
@keyframes shop-bob { 0%, 100% { transform: translateY(0); } 50% { transform: translateY(-7px); } }
@keyframes shop-dot { 0%, 100% { opacity: 0.25; } 40% { opacity: 1; } }
@keyframes shop-rise { from { opacity: 0; transform: translateY(18px) scale(0.98); } to { opacity: 1; transform: none; } }
@keyframes shop-sheen { to { transform: translateX(120%); } }
@keyframes shop-fall {
  0% { opacity: 0; transform: translate3d(0, 0, 0) rotate(0); }
  10% { opacity: 1; }
  60% { opacity: 1; }
  100% { opacity: 0; transform: translate3d(var(--x, 0), 108vh, 0) rotate(var(--r, 540deg)); }
}
@keyframes shop-glint { 0%, 55% { left: -40%; } 85%, 100% { left: 125%; } }
@keyframes shop-twinkle { 0%, 70%, 100% { opacity: 0; transform: scale(0.3) rotate(0); } 82% { opacity: 1; transform: scale(1) rotate(45deg); } }
.shop-who { margin: 0 0 14px; font-size: 1.25rem; overflow-wrap: anywhere; }
.shop-meta { display: flex; flex-wrap: wrap; gap: 10px; margin: 0 0 18px; }
.shop-meta > div { flex: 1 1 140px; padding: 10px 12px; background: var(--shop-well); border-radius: 10px; }
.shop-meta > div[hidden] { display: none; }
.shop-meta dt { color: var(--shop-faint); font-size: 0.75rem; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; }
.shop-meta dd { margin: 2px 0 0; font-weight: 650; overflow-wrap: anywhere; }
.shop-key-label { margin: 0 0 6px; color: var(--shop-faint); font-size: 0.75rem; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; }
.shop-key {
  max-height: 9.5em; overflow: auto; padding: 12px 14px; background: var(--shop-well); border: 1px solid var(--shop-line); border-radius: 10px;
  font-family: ui-monospace, "Cascadia Mono", Consolas, monospace; font-size: 0.8rem; line-height: 1.5; word-break: break-all; white-space: pre-wrap; user-select: all;
}
/* the key of the thank-you page: a champagne-gold edge (a gradient on the border box under the well's padding box), a
   slow glint across it */
.shop-thanks .shop-key {
  position: relative; border: 1px solid transparent;
  background: linear-gradient(var(--shop-well), var(--shop-well)) padding-box,
              linear-gradient(115deg, rgba(255, 214, 120, 0.7), rgba(255, 214, 120, 0.18) 45%, rgba(255, 214, 120, 0.7)) border-box;
  box-shadow: 0 0 22px rgba(255, 205, 100, 0.08);
}
.shop-thanks .shop-key::after {
  content: ""; position: absolute; top: 0; bottom: 0; left: -40%; width: 30%; pointer-events: none; transform: skewX(-18deg);
  background: linear-gradient(100deg, transparent, rgba(255, 236, 190, 0.16), transparent);
  animation: shop-glint 7s 1.5s ease-in-out infinite;
}
.shop-actions { display: flex; flex-wrap: wrap; gap: 10px; margin: 18px 0 0; }
.shop-actions > * { flex: 1 1 200px; width: auto; }
/* Download: a file's icon, then its words over the extension, as on a file's label: two lines on purpose */
.shop-download { gap: 12px; padding-top: 10px; padding-bottom: 10px; text-align: left; }
.shop-download .shop-file { flex: none; }
.shop-download-words { display: flex; flex-direction: column; align-items: flex-start; gap: 3px; min-width: 0; line-height: 1.15; }
.shop-ext {
  max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; padding: 1px 7px; border-radius: 6px;
  background: rgba(0, 0, 0, 0.12); color: inherit; font-family: ui-monospace, "SF Mono", "Cascadia Mono", Menlo, Consolas, monospace;
  font-size: 0.82rem; font-weight: 600; letter-spacing: 0.01em;
}
/* both labels of Copy sit in one grid cell: the button is as wide as the longer one and never changes size */
.shop-copy { display: grid; place-items: center; }
.shop-copy > span { grid-area: 1 / 1; display: inline-flex; align-items: center; gap: 8px; }
.shop-copy .shop-copy-done, .shop-copy.shop-done .shop-copy-ready { visibility: hidden; }
.shop-copy.shop-done .shop-copy-done { visibility: visible; }
.shop-thanks .shop-h2 { margin-top: 40px; }
.shop-thanks > div > p { color: var(--shop-muted); line-height: 1.6; }
/* the help under the licence: what to do when something is wrong, a button to ask, the way back; its tint and its edge
   are the accent, each a pseudo-element with an opacity */
.shop-help {
  position: relative; isolation: isolate; display: flex; align-items: flex-start; gap: 20px; margin: 44px 0 0; padding: 22px 26px;
  border-radius: 14px;
}
.shop-help::before, .shop-help::after { content: ""; position: absolute; z-index: -1; inset: 0; border-radius: inherit; pointer-events: none; }
.shop-help::before { background: var(--shop-accent); opacity: 0.07; }
.shop-help::after { border: 1px solid var(--shop-accent); opacity: 0.3; }
.shop-help-icon { position: relative; isolation: isolate; flex: none; display: grid; place-items: center; width: 56px; height: 56px; border-radius: 50%; color: var(--shop-accent); }
.shop-help-icon::before { content: ""; position: absolute; z-index: -1; inset: 0; border-radius: 50%; background: currentColor; opacity: 0.14; }
.shop-help-icon svg { display: block; }
.shop-thanks .shop-help .shop-h2 { margin: 2px 0 8px; font-size: 1.2rem; }
.shop-help p { margin: 0 0 14px; color: var(--shop-muted); line-height: 1.6; }
.shop-help p strong { color: var(--shop-text); }
.shop-help-links { display: flex; flex-wrap: wrap; align-items: center; gap: 12px 20px; }
.shop-page .shop-help-links .shop-buy { width: auto; min-height: 42px; padding: 9px 20px; font-size: 0.98rem; color: var(--shop-ink); text-decoration: none; }

/* less motion asked: nothing moves, the stars and the confetti are not shown (the script skips the confetti too) */
@media (prefers-reduced-motion: reduce) {
  .shop-buy, .shop-quiet { transition: none; }
  .shop-buy:hover, .shop-buy:active { transform: none; }
  .shop-logo, .shop-dots i, .shop-thanks .shop-key::after, .shop-spark, .shop-confetti b,
  .shop-thanks[data-state="ready"] .shop-card, .shop-thanks[data-state="ready"] .shop-card::after { animation: none; }
  .shop-dots i { opacity: 0.6; }
  .shop-spark, .shop-confetti, .shop-thanks .shop-key::after { display: none; }
}

/* the foot: the shop's pages and the home */
.shop-foot { border-top: 1px solid var(--shop-line); padding: 26px 0 40px; }
.shop-foot nav { display: flex; flex-wrap: wrap; justify-content: center; gap: 8px 22px; font-size: 0.92rem; }
.shop-page .shop-foot a { color: var(--shop-muted); text-decoration: none; }
.shop-page .shop-foot a:hover, .shop-page .shop-foot a[aria-current] { color: var(--shop-text); }

@media (max-width: 720px) {
  .shop-facts { grid-template-columns: minmax(0, 1fr); }
}
@media (max-width: 480px) {
  .shop-wrap { padding: 0 16px; }
  .shop-hero { padding: 44px 16px 28px; }
  .shop-hero::before { width: 360px; margin-left: -180px; top: -120px; }
  .shop-icon { width: 72px; height: 72px; }
  .shop-stage, .shop-logo { width: 84px; height: 84px; }
  .shop-help { flex-direction: column; padding: 20px 18px; }
  .shop-offer { padding: 24px 20px 20px; border-radius: 16px; }
  .shop-amount { font-size: 3rem; }
  .shop-section { padding-top: 44px; }
  .shop-thanks { padding: 0 16px; }
  .shop-card { padding: 20px 18px; }
  .shop-back { display: none; }
}
`
