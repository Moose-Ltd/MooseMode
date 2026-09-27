#!/usr/bin/env node
// make_arrow.js -- renders the MooseMode waypoint arrow.
//
// Output:
//   MooseMode/media/arrow.tga        128x128, uncompressed 32-bit TGA, top-left origin (what WoW loads)
//   tools/arrow_preview.png          same image as PNG, for eyeballing
//   tools/arrow_preview_context.png  the arrow at in-game size on light and dark ground, scaled up
//
// No dependencies beyond Node's zlib. Run: node tools/make_arrow.js
//
// Design: a navigation dart pointing up (the texture's top is "ahead"), with
// a notched back. Two facets split down the middle (left lit, right shaded)
// give it depth; the fill runs from pale lavender at the tip to MooseMode
// purple at the base. A thin dark outline keeps it readable on bright
// ground, and a soft purple glow on dark ground. 4x4 supersampling.

"use strict";
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const SIZE = 128;
const SS = 4;

const ROOT = path.resolve(__dirname, "..");
const OUT_TGA = path.join(ROOT, "MooseMode", "media", "arrow.tga");
const OUT_PNG = path.join(ROOT, "tools", "arrow_preview.png");
const OUT_CTX = path.join(ROOT, "tools", "arrow_preview_context.png");

function hex(h) {
    const n = parseInt(h.slice(1), 16);
    return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255];
}
function lerp(a, b, t) { return a + (b - a) * t; }
function mix(c1, c2, t) { return [lerp(c1[0], c2[0], t), lerp(c1[1], c2[1], t), lerp(c1[2], c2[2], t)]; }
function clamp01(v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
function smooth(e0, e1, x) { const t = clamp01((x - e0) / (e1 - e0)); return t * t * (3 - 2 * t); }
function over(dst, src) {
    const a = src[3] + dst[3] * (1 - src[3]);
    if (a <= 0) return [0, 0, 0, 0];
    return [
        (src[0] * src[3] + dst[0] * dst[3] * (1 - src[3])) / a,
        (src[1] * src[3] + dst[1] * dst[3] * (1 - src[3])) / a,
        (src[2] * src[3] + dst[2] * dst[3] * (1 - src[3])) / a,
        a,
    ];
}

// Palette
const TIP_LIT    = hex("#F1E6FF");   // lit facet at the tip
const BASE_LIT   = hex("#B47CFF");   // lit facet at the base
const TIP_SHADE  = hex("#C9A2FF");   // shaded facet at the tip
const BASE_SHADE = hex("#7A2FE0");   // shaded facet at the base
const OUTLINE    = hex("#1C0835");
const GLOW       = hex("#A45CFF");
const RIDGE      = hex("#FFFFFF");   // thin highlight along the centre ridge

// Geometry (128px space, y down). Tip, right wing, notch, left wing.
const TIP   = [64, 12];
const RWING = [104, 110];
const NOTCH = [64, 86];
const LWING = [24, 110];
const POLY = [TIP, RWING, NOTCH, LWING];
const OUTLINE_W = 3;
const GLOW_W = 9;
const GLOW_A = 0.5;

// Signed distance to the polygon: negative inside.
function segDist(px, py, a, b) {
    const vx = b[0] - a[0], vy = b[1] - a[1];
    const wx = px - a[0], wy = py - a[1];
    const t = clamp01((wx * vx + wy * vy) / (vx * vx + vy * vy));
    const dx = wx - vx * t, dy = wy - vy * t;
    return Math.sqrt(dx * dx + dy * dy);
}
function inside(px, py) {
    let c = false;
    for (let i = 0, j = POLY.length - 1; i < POLY.length; j = i++) {
        const [xi, yi] = POLY[i], [xj, yj] = POLY[j];
        if ((yi > py) !== (yj > py) && px < (xj - xi) * (py - yi) / (yj - yi) + xi) c = !c;
    }
    return c;
}
function sdf(px, py) {
    let d = Infinity;
    for (let i = 0; i < POLY.length; i++) d = Math.min(d, segDist(px, py, POLY[i], POLY[(i + 1) % POLY.length]));
    return inside(px, py) ? -d : d;
}

function sample(px, py) {
    const d = sdf(px, py);
    let out = [0, 0, 0, 0];
    // Soft glow outside the outline.
    if (d > 0) {
        const g = GLOW_A * (1 - smooth(0, GLOW_W, d));
        out = over(out, [GLOW[0], GLOW[1], GLOW[2], g]);
        return out;
    }
    if (d > -OUTLINE_W) return [OUTLINE[0], OUTLINE[1], OUTLINE[2], 1];
    // Fill: vertical gradient tip -> base, per facet.
    const t = clamp01((py - TIP[1]) / (LWING[1] - TIP[1]));
    const lit = px < 64;
    let c = lit ? mix(TIP_LIT, BASE_LIT, t) : mix(TIP_SHADE, BASE_SHADE, t);
    // A fine bright ridge down the centre, fading towards the notch.
    const ridge = (1 - smooth(0.4, 1.4, Math.abs(px - 64))) * (1 - t) * 0.55;
    c = mix(c, RIDGE, ridge);
    return [c[0], c[1], c[2], 1];
}

function render() {
    const img = new Float32Array(SIZE * SIZE * 4);
    const inv = 1 / (SS * SS);
    for (let y = 0; y < SIZE; y++) {
        for (let x = 0; x < SIZE; x++) {
            let r = 0, g = 0, b = 0, a = 0;
            for (let sy = 0; sy < SS; sy++) {
                for (let sx = 0; sx < SS; sx++) {
                    const s = sample(x + (sx + 0.5) / SS, y + (sy + 0.5) / SS);
                    r += s[0] * s[3]; g += s[1] * s[3]; b += s[2] * s[3]; a += s[3];
                }
            }
            const i = (y * SIZE + x) * 4;
            if (a > 0) { img[i] = r / a; img[i + 1] = g / a; img[i + 2] = b / a; img[i + 3] = a * inv; }
        }
    }
    return img;
}

function toBytes(img, w, h) {
    const out = Buffer.alloc(w * h * 4);
    for (let i = 0; i < w * h * 4; i++) out[i] = Math.round(clamp01(img[i]) * 255);
    return out;
}

function writeTGA(file, rgba, w, h) {
    const hdr = Buffer.alloc(18, 0);
    hdr[2] = 2;
    hdr.writeUInt16LE(w, 12);
    hdr.writeUInt16LE(h, 14);
    hdr[16] = 32;
    hdr[17] = 0x28;
    const body = Buffer.alloc(w * h * 4);
    for (let i = 0; i < w * h; i++) {
        body[i * 4] = rgba[i * 4 + 2];
        body[i * 4 + 1] = rgba[i * 4 + 1];
        body[i * 4 + 2] = rgba[i * 4];
        body[i * 4 + 3] = rgba[i * 4 + 3];
    }
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, Buffer.concat([hdr, body]));
}

const CRC_TABLE = (() => {
    const t = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
        let c = n;
        for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
        t[n] = c >>> 0;
    }
    return t;
})();
function crc32(buf) {
    let c = 0xFFFFFFFF;
    for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 255] ^ (c >>> 8);
    return (c ^ 0xFFFFFFFF) >>> 0;
}
function chunk(type, data) {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
    const td = Buffer.concat([Buffer.from(type, "ascii"), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td), 0);
    return Buffer.concat([len, td, crc]);
}
function writePNG(file, rgba, w, h) {
    const sig = Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
    ihdr[8] = 8; ihdr[9] = 6;
    const raw = Buffer.alloc((w * 4 + 1) * h);
    for (let y = 0; y < h; y++) rgba.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, Buffer.concat([sig, chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(raw, { level: 9 })), chunk("IEND", Buffer.alloc(0))]));
}

// Context: the arrow at 44px (in-game size), rotated a little, on a light
// and a dark tile, scaled up 3x with nearest-neighbour to show real pixels.
function context(img) {
    const TILE = 64, N = 44, UP = 3;
    const W = TILE * 2 * UP, H = TILE * UP;
    const out = Buffer.alloc(W * H * 4);
    const grounds = [hex("#C8B48A"), hex("#1E2A1E")];
    const ang = 0.5;
    for (let t = 0; t < 2; t++) {
        for (let y = 0; y < TILE; y++) {
            for (let x = 0; x < TILE; x++) {
                // Inverse-rotate into arrow space, then scale to the 128px texture.
                const cx = x + 0.5 - TILE / 2, cy = y + 0.5 - TILE / 2;
                const rx = cx * Math.cos(ang) + cy * Math.sin(ang);
                const ry = -cx * Math.sin(ang) + cy * Math.cos(ang);
                const u = Math.floor((rx / N + 0.5) * SIZE), v = Math.floor((ry / N + 0.5) * SIZE);
                let c = [...grounds[t], 1];
                if (u >= 0 && u < SIZE && v >= 0 && v < SIZE) {
                    const i = (v * SIZE + u) * 4;
                    c = over(c, [img[i], img[i + 1], img[i + 2], img[i + 3] * 0.9]);
                }
                for (let dy = 0; dy < UP; dy++) for (let dx = 0; dx < UP; dx++) {
                    const o = (((y * UP + dy) * W) + (t * TILE + x) * UP + dx) * 4;
                    out[o] = Math.round(clamp01(c[0]) * 255);
                    out[o + 1] = Math.round(clamp01(c[1]) * 255);
                    out[o + 2] = Math.round(clamp01(c[2]) * 255);
                    out[o + 3] = 255;
                }
            }
        }
    }
    writePNG(OUT_CTX, out, W, H);
}

const img = render();
const bytes = toBytes(img, SIZE, SIZE);
writeTGA(OUT_TGA, bytes, SIZE, SIZE);
writePNG(OUT_PNG, bytes, SIZE, SIZE);
context(img);
console.log("wrote", path.relative(ROOT, OUT_TGA), path.relative(ROOT, OUT_PNG), path.relative(ROOT, OUT_CTX));
