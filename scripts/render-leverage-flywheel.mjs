#!/usr/bin/env node
/**
 * Renders the /leverage explainer illustration — the Leveraged Hooks credit loop and the
 * $HOOKR bond ladder — as an SVG, plus a PNG for posting.
 *
 * Written as a generator rather than a hand-drawn file for the same reason the OG cards are:
 * every number and colour in it is read from the spec module, so the picture cannot drift away
 * from the page it illustrates. The cube geometry is the same isometric construction as
 * src/lib/og/voxel-svg.ts (a diamond top plus two skewY(±26.57°) faces, tan = 0.5).
 *
 * Every label is claims-register clean: design parameters only, no measurements, and the
 * "nothing deployed" chip is not optional.
 *
 *   node scripts/render-leverage-flywheel.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const W = 1600;
const H = 900;

/* ------------------------------------------------------------------ palette (globals.css) */

const C = {
  ink: "#21103a",
  pageBg: "#f3e7f8",
  card: "#ffffff",
  magenta: "#f50db4",
  brandTop: "#FF63D2",
  brandSide: "#F50DB4",
  brandDark: "#A00873",
  divider: "#eed9f6",
  chipLilac: "#f6dffb",
  textMuted: "#8a6ba6",
  textMid: "#6b4a85",
  textStrong: "#5a3b77",
  danger: "#d92626",
  success: "#1d8a4a",
};

/** Mirrors RISK_TIERS in src/lib/module-market.ts — keep in sync by name, not by guess. */
const TIERS = [
  { id: "read", n: 0, name: "READ-ONLY", band: "0 – 10,000", top: "#E8DAF3", side: "#C9AEDD", dark: "#A98BC4" },
  { id: "params", n: 1, name: "PARAMETERS", band: "25,000 – 100,000", top: "#7EA5FF", side: "#4C82FB", dark: "#2F56B8" },
  { id: "assets", n: 2, name: "ASSET MOVEMENT", band: "100,000 – 250,000", top: "#FFB25C", side: "#FF8A00", dark: "#BD5F00" },
  { id: "credit", n: 3, name: "CREDIT + LEVERAGE", band: "250,000+", top: "#FF7E7E", side: "#FF4D4D", dark: "#BE2B2B" },
];

/** Mirrors REVENUE_ROUTES — min/max are the published bounds, not a measurement. */
const ROUTES = [
  { name: "MODULE DEVELOPER", min: 20, max: 60, color: C.brandSide, note: "20–60%" },
  { name: "$HOOKR BACKERS", min: 10, max: 40, color: "#FF8A00", note: "10–40%" },
  { name: "HOOKR.FUN", min: 15, max: 15, color: "#4C82FB", note: "15% FIXED" },
  { name: "MODULE SAFETY RESERVE", min: 10, max: 10, color: C.success, note: "10% MINIMUM" },
];

/* ------------------------------------------------------------------ primitives */

const esc = (s) =>
  String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/** One isometric cube's three faces, translated to (x, y). Geometry from og/voxel-svg.ts. */
function cube(x, y, size, depth, f) {
  const D = size / 2;
  const T = depth;
  const top = `${x + D},${y} ${x + size},${y + D / 2} ${x + D},${y + D} ${x},${y + D / 2}`;
  const left = `${x},${y + D / 2} ${x + D},${y + D} ${x + D},${y + D + T} ${x},${y + D / 2 + T}`;
  const right = `${x + D},${y + D} ${x + size},${y + D / 2} ${x + size},${y + D / 2 + T} ${x + D},${y + D + T}`;
  return (
    `<polygon points="${top}" fill="${f.top}"/>` +
    `<polygon points="${left}" fill="${f.side}"/>` +
    `<polygon points="${right}" fill="${f.dark}"/>`
  );
}

const pix = (x, y, t, size = 16, fill = C.ink, anchor = "start", weight = 400) =>
  `<text x="${x}" y="${y}" font-family="Silkscreen" font-weight="${weight}" font-size="${size}" fill="${fill}" text-anchor="${anchor}" letter-spacing="0.5">${esc(t)}</text>`;

const body = (x, y, t, size = 20, fill = C.textMid, anchor = "start") =>
  `<text x="${x}" y="${y}" font-family="Chakra Petch" font-size="${size}" fill="${fill}" text-anchor="${anchor}">${esc(t)}</text>`;

/** A bordered chip in the site's convention. */
function chip(x, y, label, { fg = C.ink, bg = C.card, bd = C.ink, size = 15, padX = 12, h = 32 } = {}) {
  const w = label.length * size * 0.78 + padX * 2;
  return (
    `<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="${bg}" stroke="${bd}" stroke-width="2.5"/>` +
    pix(x + w / 2, y + h / 2 + size * 0.36, label, size, fg, "middle") +
    `<!--w:${w}-->`
  );
}
const chipWidth = (label, size = 15, padX = 12) => label.length * size * 0.78 + padX * 2;

/** Right-pointing arrow between pipeline stages. */
const arrowRight = (x, y, len = 20, color = C.textStrong) =>
  `<path d="M${x} ${y} H${x + len}" stroke="${color}" stroke-width="3"/>` +
  `<polygon points="${x + len},${y - 6} ${x + len + 10},${y} ${x + len},${y + 6}" fill="${color}"/>`;

/* ------------------------------------------------------------------ composition */

let art = "";

// ---- background: page tint + the site's checker texture + a hard frame
art +=
  `<rect width="${W}" height="${H}" fill="${C.pageBg}"/>` +
  `<rect width="${W}" height="${H}" fill="url(#checker)"/>`;

// ---- header
art += `<rect x="56" y="42" width="42" height="42" fill="${C.magenta}"/>`;
art += pix(66, 74, "H", 30, C.card);
art += pix(112, 74, "HOOKR.FUN", 30, C.ink);

{
  const chips = [
    { label: "DESIGN SPEC", fg: C.ink, bd: C.ink, bg: C.chipLilac },
    { label: "NOTHING DEPLOYED", fg: C.danger, bd: C.danger, bg: C.card },
  ];
  let x = W - 56;
  for (const c of [...chips].reverse()) {
    const w = chipWidth(c.label);
    x -= w;
    art += chip(x, 45, c.label, c);
    x -= 12;
  }
}

// ---- title
art += pix(56, 178, "LEVERAGED HOOKS", 58, C.ink, "start", 700);
art += body(
  56,
  218,
  "A market's trading liquidity, lending too — credit extended by the pool itself, not a vault beside it.",
  22,
  C.textStrong,
);

// ---- divider
art += `<rect x="56" y="244" width="${W - 112}" height="3" fill="${C.ink}"/>`;

/* ---------------------------------------------------------------- left: the bond ladder */

const LX = 56;
art += pix(LX, 292, "RISK TIER → $HOOKR BOND", 17, C.ink, "start", 700);

{
  const size = 84;
  const depth = 28;
  const rowH = 100;
  const top = 316;
  // Highest tier first, so the ladder reads as a climb with credit at the summit.
  [...TIERS].reverse().forEach((t, i) => {
    const y = top + i * rowH;
    art += cube(LX + 6, y, size, depth, t);
    const cy = y + 34;
    art += pix(LX + 108, cy, `TIER ${t.n} · ${t.name}`, 15, C.ink, "start", 700);
    art += body(LX + 108, cy + 24, `${t.band} $HOOKR`, 19, C.textMuted);
    if (t.id === "credit") {
      art += chip(LX + 108, cy + 34, "LEVERAGED HOOKS", {
        fg: C.danger,
        bd: C.danger,
        bg: "#ffeaea",
        size: 13,
        h: 28,
      });
    }
  });
}

art += `<rect x="${LX}" y="728" width="404" height="3" fill="${C.divider}"/>`;
art += body(LX, 760, "Credit capacity is the most conservative", 19, C.textMid);
art += body(LX, 784, "of liquidity, liquidation depth, bonded", 19, C.textMid);
art += body(LX, 808, "$HOOKR and a protocol limit.", 19, C.textMid);

/* ---------------------------------------------------------------- right: the loop */

const RX = 520;
const RW = W - 56 - RX;
art += pix(RX, 292, "THE LOOP", 17, C.ink, "start", 700);

{
  const stages = [
    { a: "TRADER", b: "POSTS EQUITY", t: TIERS[0] },
    { a: "MARKET", b: "EXTENDS CREDIT", t: TIERS[1] },
    { a: "TOKENS LOCK", b: "AS COLLATERAL", t: TIERS[2] },
    { a: "DEBT ON", b: "THE SHEET", t: TIERS[3] },
    { a: "FEES + INTEREST", b: "TO LPS", t: TIERS[1] },
  ];
  const gap = 20;
  const bw = (RW - gap * (stages.length - 1)) / stages.length;
  const by = 316;
  const bh = 128;

  stages.forEach((s, i) => {
    const x = RX + i * (bw + gap);
    art +=
      `<rect x="${x}" y="${by}" width="${bw}" height="${bh}" fill="${C.card}" stroke="${C.ink}" stroke-width="3"/>` +
      cube(x + bw / 2 - 19, by + 16, 38, 13, s.t) +
      pix(x + bw / 2, by + 88, s.a, 14, C.ink, "middle", 700) +
      pix(x + bw / 2, by + 110, s.b, 14, C.textMuted, "middle");
    if (i < stages.length - 1) art += arrowRight(x + bw + 2, by + bh / 2, gap - 14);
  });

  // The return leg — without it this is a pipeline, not a flywheel.
  const y0 = by + bh;
  const yBend = y0 + 46;
  const xEnd = RX + RW - bw / 2;
  const xStart = RX + bw / 2;
  art +=
    `<path d="M${xEnd} ${y0} V${yBend} H${xStart} V${y0 + 12}" fill="none" stroke="${C.brandSide}" stroke-width="3" stroke-dasharray="8 6"/>` +
    `<polygon points="${xStart - 7},${y0 + 14} ${xStart + 7},${y0 + 14} ${xStart},${y0} " fill="${C.brandSide}"/>`;
  // Plate sized from the caption's own measured advance (Silkscreen sits near 0.8em) so the
  // dashed return leg cannot clip the ends of the text.
  const caption = "ONE POOL · ONE LIQUIDITY BASE · SPOT + LEVERAGE";
  const capW = caption.length * 15 * 0.8 + 28;
  art += `<rect x="${RX + RW / 2 - capW / 2}" y="${yBend - 17}" width="${capW}" height="34" fill="${C.pageBg}"/>`;
  art += pix(RX + RW / 2, yBend + 6, caption, 15, C.brandDark, "middle", 700);
}

/* ---------------------------------------------------------------- right: fee routing */

art += pix(RX, 566, "WHERE MODULE FEES GO", 17, C.ink, "start", 700);
// End-anchored so it can never collide with the header, whatever the pixel font measures.
art += body(W - 56, 566, "developer-set, within published bounds", 19, C.textMuted, "end");

{
  const trackX = RX + 300;
  const trackW = RW - 300 - 132;
  const rowY = 596;
  const rowH = 40;

  ROUTES.forEach((r, i) => {
    const y = rowY + i * rowH;
    art += pix(RX, y + 14, r.name, 14, C.textStrong, "start", 700);
    art += `<rect x="${trackX}" y="${y}" width="${trackW}" height="20" fill="${C.card}" stroke="${C.divider}" stroke-width="2"/>`;
    const x0 = trackX + (r.min / 100) * trackW;
    const x1 = trackX + (r.max / 100) * trackW;
    art += `<rect x="${x0}" y="${y}" width="${Math.max(x1 - x0, 5)}" height="20" fill="${r.color}"/>`;
    art += pix(trackX + trackW + 14, y + 15, r.note, 14, C.ink, "start", 700);
  });

  art += body(
    RX,
    rowY + ROUTES.length * rowH + 30,
    "Nothing is minted to pay any of it. A module nobody installs routes nothing at all.",
    19,
    C.textMid,
  );
}

/* ---------------------------------------------------------------- footer */

art += `<rect x="56" y="846" width="${W - 112}" height="2" fill="${C.divider}"/>`;
art += pix(56, 878, "HOOKR.FUN/LEVERAGE", 16, C.magenta, "start", 700);
art += body(
  W - 56,
  878,
  "Published design — no registry, bond vault or fee router on chain. Not financial advice.",
  19,
  C.textMuted,
  "end",
);

/* ------------------------------------------------------------------ assemble */

function fontFace(family, file, weight) {
  const b64 = readFileSync(join(ROOT, "assets/og-fonts", file)).toString("base64");
  return `@font-face{font-family:'${family}';font-weight:${weight};src:url(data:font/ttf;base64,${b64}) format('truetype');}`;
}

// Family names must match the `font-family` attributes above EXACTLY, including the space in
// "Chakra Petch" — a mismatch does not error, it silently falls back to a serif.
const css =
  fontFace("Silkscreen", "Silkscreen-Regular.ttf", 400) +
  fontFace("Silkscreen", "Silkscreen-Bold.ttf", 700) +
  fontFace("Chakra Petch", "ChakraPetch-Regular.ttf", 400);

const svg =
  `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">` +
  `<defs><style>${css}</style>` +
  `<pattern id="checker" width="40" height="40" patternUnits="userSpaceOnUse">` +
  `<rect width="20" height="20" fill="rgba(140,80,170,0.07)"/>` +
  `<rect x="20" y="20" width="20" height="20" fill="rgba(140,80,170,0.07)"/>` +
  `</pattern></defs>` +
  art +
  `<rect x="3" y="3" width="${W - 6}" height="${H - 6}" fill="none" stroke="${C.ink}" stroke-width="6"/>` +
  `</svg>`;

const outSvg = join(ROOT, "public/leverage-flywheel.svg");
mkdirSync(dirname(outSvg), { recursive: true });
writeFileSync(outSvg, svg);
console.log(`svg  ${outSvg} (${(svg.length / 1024).toFixed(0)} KB)`);

/*
 * SVG only, by default, and that is deliberate.
 *
 * The pixel font is embedded in the file as a base64 @font-face, which browsers honour and
 * librsvg does not — rsvg-convert and sharp both silently fall back to a generic sans, which
 * throws away the one typeface the art depends on and looks fine enough that nobody notices.
 * macOS Quick Look renders the faces correctly but forces a square canvas, so it distorts a
 * 16:9 board.
 *
 * So the SVG is the deliverable: open it in a browser to view, and export from there if a
 * raster is needed. Passing --png writes one anyway for a quick look at layout, with the
 * wrong typeface — it is a proof, not an asset.
 */
if (process.argv.includes("--png")) {
  const outPng = join(ROOT, ".next/cache/flywheel-layout.png");
  mkdirSync(dirname(outPng), { recursive: true });
  execFileSync("rsvg-convert", ["-w", String(W), "-h", String(H), "-o", outPng, outSvg]);
  console.warn(`png  ${outPng} — LAYOUT PROOF ONLY, fonts fall back to sans`);
}
