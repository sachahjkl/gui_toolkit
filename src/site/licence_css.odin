package tk_site

// The style of the shop's pages (licence_pages/*.html put it in their head as {{shop_css}}): the bar, the hero, the offer's
// card, its button, the facts before buying, the licence card of the thank-you page, the legal pages' column, the foot.
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
//   --accent               the button, the check marks, the hero's glow
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
.shop-page a { color: var(--shop-accent); }
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
.shop-icon { display: block; margin: 0 auto 18px; border-radius: 20px; box-shadow: 0 12px 32px rgba(0, 0, 0, 0.32); }
.shop-eyebrow { margin: 0 0 4px; color: var(--shop-accent); font-size: 0.82rem; font-weight: 700; letter-spacing: 0.12em; text-transform: uppercase; }
.shop-name { margin: 0 0 12px; font-size: clamp(2.6rem, 10vw, 4.2rem); line-height: 1.02; letter-spacing: -0.03em; overflow-wrap: anywhere; }
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

/* a legal page: one readable column */
.shop-doc { max-width: 720px; padding-top: 48px; line-height: 1.65; }
.shop-doc h1 { margin: 0 0 6px; font-size: clamp(2rem, 7vw, 2.6rem); letter-spacing: -0.02em; }
.shop-doc h2 { margin: 32px 0 8px; font-size: 1.2rem; }
.shop-doc > p { color: var(--shop-muted); }
.shop-doc .shop-fine { margin: 0 0 24px; }

/* the thank-you page: the status, then the licence card */
.shop-thanks { max-width: 620px; margin: 0 auto; padding: 0 20px; }
.shop-wait { display: flex; align-items: center; justify-content: center; gap: 12px; margin: 0 0 24px; color: var(--shop-muted); text-align: center; }
.shop-spinner {
  flex: none; width: 18px; height: 18px; border-radius: 50%;
  border: 2px solid var(--shop-line); border-top-color: var(--shop-accent); animation: shop-spin 0.9s linear infinite;
}
.shop-thanks:not([data-state="waiting"]) .shop-spinner { display: none; }
.shop-thanks[data-state="failed"] .shop-wait { color: var(--shop-text); text-align: left; }
@keyframes shop-spin { to { transform: rotate(360deg); } }
@media (prefers-reduced-motion: reduce) {
  .shop-spinner { animation-duration: 2.4s; }
  .shop-buy, .shop-quiet { transition: none; }
  .shop-buy:hover, .shop-buy:active { transform: none; }
}
.shop-card {
  position: relative; overflow: hidden; padding: 26px; background: var(--shop-card); border: 1px solid var(--shop-line);
  border-radius: 18px; box-shadow: 0 24px 60px -24px rgba(0, 0, 0, 0.5);
}
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
.shop-actions { display: flex; flex-wrap: wrap; gap: 10px; margin: 18px 0 0; }
.shop-actions > * { flex: 1 1 200px; width: auto; }
.shop-thanks .shop-h2 { margin-top: 40px; }
.shop-thanks > div > p { color: var(--shop-muted); line-height: 1.6; }

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
  .shop-icon { width: 72px; height: 72px; border-radius: 16px; }
  .shop-offer { padding: 24px 20px 20px; border-radius: 16px; }
  .shop-amount { font-size: 3rem; }
  .shop-section { padding-top: 44px; }
  .shop-thanks { padding: 0 16px; }
  .shop-card { padding: 20px 18px; }
  .shop-back { display: none; }
}
`
