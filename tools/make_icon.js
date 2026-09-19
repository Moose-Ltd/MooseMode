#!/usr/bin/env node
// make_icon.js -- renders the MooseMode minimap icon.
//
// Output:
//   MooseMode/media/icon.tga          128x128, uncompressed 32-bit TGA, top-left origin (what WoW loads)
//   tools/icon_preview.png            same image as PNG, for eyeballing
//   tools/icon_preview_context.png    the icon at minimap size (20px) on a fake minimap, to judge legibility
//
// No dependencies beyond Node's zlib. Run: node tools/make_icon.js
//
// Design: a purple orb (radial gradient, specular highlight, bright rim, soft
// outer glow) with a four-point white sparkle in the centre. Everything is
// rendered with 4x4 supersampling so the edges are clean at any size.

"use strict";
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const SIZE = 128;
const SS = 4;                      // supersample factor per axis
const C = SIZE / 2;                // centre

const ROOT = path.resolve(__dirname, "..");
const OUT_TGA = path.join(ROOT, "MooseMode", "media", "icon.tga");
const OUT_PNG = path.join(ROOT, "tools", "icon_preview.png");
const OUT_CTX = path.join(ROOT, "tools", "icon_preview_context.png");

// ---------------------------------------------------------------------------
// Colour helpers (all linear-ish 0..1 floats; we are not doing gamma-correct
// blending, the look was tuned by eye in sRGB).
// ---------------------------------------------------------------------------

function hex(h) {
    const n = parseInt(h.slice(1), 16);
    return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255];
}
function lerp(a, b, t) { return a + (b - a) * t; }
function mix(c1, c2, t) { return [lerp(c1[0], c2[0], t), lerp(c1[1], c2[1], t), lerp(c1[2], c2[2], t)]; }
function clamp01(v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
function smooth(edge0, edge1, x) {
    const t = clamp01((x - edge0) / (edge1 - edge0));
    return t * t * (3 - 2 * t);
}
// "over" compositing of premultiplied-free RGBA: src over dst
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

// ---------------------------------------------------------------------------
// Palette
// ---------------------------------------------------------------------------

const ORB_HI   = hex("#8A44F2");   // orb centre (highlight side)
const ORB_LO   = hex("#2B0B52");   // orb edge
const RIM_HI   = hex("#B98CFF");   // rim, light side
const RIM_LO   = hex("#6B35D0");   // rim, dark side
const GLOW     = hex("#9D5CFF");   // outer glow
const SPARK_CORE = hex("#FFFFFF");
const SPARK_TIP  = hex("#E6D4FF");
const BLOOM    = hex("#C79BFF");

// Geometry (in 128px space)
const R_DISC = 58;                 // orb radius
const RIM_W = 2.5;                 // rim width
const GLOW_W = 5;                  // outer glow beyond rim
const HI_CX = 54, HI_CY = 50;      // gradient centre (highlight offset)
const SPEC_CX = 48, SPEC_CY = 44, SPEC_R = 22;
const STAR_LONG = 40;              // long points (vertical/horizontal)
const STAR_SHORT = 19;             // short points (diagonal)
const STAR_P = 0.6;                // superellipse exponent: lower = thinner points
const STAR_P_SHORT = 0.56;
const BLOOM_W = 6;

// ---------------------------------------------------------------------------
// Shape functions -- each returns a coverage 0..1 at a given point, with a
// soft edge of about 1px in 128-space so the supersampling has something to
// average.
// ---------------------------------------------------------------------------

// Superellipse |x|^p + |y|^p <= R^p, rotated by `rot` radians. Returns signed
// "distance-ish" value: <0 inside. Using p=0.5 gives the pinched sparkle.
function sparkleField(x, y, R, rot, p) {
    const cs = Math.cos(rot), sn = Math.sin(rot);
    const rx = x * cs + y * sn;
    const ry = -x * sn + y * cs;
    const ax = Math.abs(rx), ay = Math.abs(ry);
    // (|x|^p + |y|^p)^(1/p) is the "radius" under this norm; compare with R
    const rad = Math.pow(Math.pow(ax, p) + Math.pow(ay, p), 1 / p);
    return rad - R;
}

function sample(px, py) {
    // px,py are in 128-space, sub-pixel precise. Returns [r,g,b,a].
    const dx = px - C, dy = py - C;
    const d = Math.sqrt(dx * dx + dy * dy);

    let out = [0, 0, 0, 0];

    // --- outer glow (beyond rim) ------------------------------------------
    const glowStart = R_DISC;
    const glowEnd = R_DISC + GLOW_W;
    if (d > glowStart - 1 && d < glowEnd + 1) {
        const t = clamp01((d - glowStart) / (glowEnd - glowStart));
        const a = 0.45 * (1 - t) * (1 - t) * (1 - smooth(glowEnd - 0.7, glowEnd + 0.3, d));
        out = over(out, [GLOW[0], GLOW[1], GLOW[2], a]);
    }

    // --- orb disc -----------------------------------------------------------
    const discCov = 1 - smooth(R_DISC - 0.8, R_DISC + 0.3, d);
    if (discCov > 0) {
        // radial gradient from the offset highlight centre
        const hx = px - HI_CX, hy = py - HI_CY;
        const hd = Math.sqrt(hx * hx + hy * hy);
        // normalise against the farthest reach of the disc from the highlight centre
        const reach = R_DISC + Math.sqrt((HI_CX - C) ** 2 + (HI_CY - C) ** 2);
        let g = clamp01(hd / reach);
        g = Math.pow(g, 1.15);
        let col = mix(ORB_HI, ORB_LO, g);

        // subtle vertical darkening towards the bottom for weight
        const vy = clamp01((dy + R_DISC) / (2 * R_DISC));
        col = mix(col, ORB_LO, 0.18 * vy);

        // specular highlight
        const sx = px - SPEC_CX, sy = py - SPEC_CY;
        const sd = Math.sqrt(sx * sx + sy * sy);
        const spec = 0.12 * (1 - smooth(0, SPEC_R, sd)) ** 1.4;
        col = mix(col, [1, 1, 1], spec);

        // rim: ring at the edge, light on the top-left, darker bottom-right
        const rimInner = R_DISC - RIM_W;
        const rimCov = smooth(rimInner - 0.8, rimInner + 0.4, d);
        if (rimCov > 0) {
            const ang = Math.atan2(dy, dx);                 // 0 = right, -pi/2 = up
            const lightDir = Math.atan2(-1, -1);            // top-left in screen space
            let facing = Math.cos(ang - lightDir);          // 1 at light side, -1 opposite
            facing = (facing + 1) / 2;
            const rimCol = mix(RIM_LO, RIM_HI, Math.pow(facing, 1.3));
            col = mix(col, rimCol, rimCov * 0.95);
        }

        out = over(out, [col[0], col[1], col[2], discCov]);
    }

    // --- sparkle bloom ------------------------------------------------------
    // Field of the union of long and short sparkles; bloom is a soft band
    // outside the shape.
    const fLong = sparkleField(dx, dy, STAR_LONG, 0, STAR_P);
    const fShort = sparkleField(dx, dy, STAR_SHORT, Math.PI / 4, STAR_P_SHORT);
    const f = Math.min(fLong, fShort);            // <0 inside either

    if (f > -1 && f < BLOOM_W + 1) {
        const t = clamp01(f / BLOOM_W);
        const a = 0.35 * (1 - t) * (1 - t);
        out = over(out, [BLOOM[0], BLOOM[1], BLOOM[2], a * (f < 0 ? 0 : 1)]);
    }

    // --- sparkle body -------------------------------------------------------
    const starCov = 1 - smooth(-0.9, 0.35, f);
    if (starCov > 0) {
        // tip fade: how far along the point we are, 0 centre .. 1 tip
        const along = clamp01(d / STAR_LONG);
        let col = mix(SPARK_CORE, SPARK_TIP, Math.pow(along, 1.6));
        // tiny warm core so it reads as a light source, not flat white
        const core = (1 - smooth(0, 7, d)) * 0.10;
        col = mix(col, [1, 0.97, 1], core);
        out = over(out, [col[0], col[1], col[2], starCov]);
    }

    return out;
}

// ---------------------------------------------------------------------------
// Render with supersampling
// ---------------------------------------------------------------------------

function render() {
    const img = new Float32Array(SIZE * SIZE * 4);
    const inv = 1 / (SS * SS);
    for (let y = 0; y < SIZE; y++) {
        for (let x = 0; x < SIZE; x++) {
            let r = 0, g = 0, b = 0, a = 0;
            for (let sy = 0; sy < SS; sy++) {
                for (let sx = 0; sx < SS; sx++) {
                    const px = x + (sx + 0.5) / SS;
                    const py = y + (sy + 0.5) / SS;
                    const s = sample(px, py);
                    // accumulate premultiplied so transparent samples don't
                    // bleed colour into the average
                    r += s[0] * s[3]; g += s[1] * s[3]; b += s[2] * s[3]; a += s[3];
                }
            }
            const i = (y * SIZE + x) * 4;
            if (a > 0) {
                img[i] = r / a; img[i + 1] = g / a; img[i + 2] = b / a; img[i + 3] = a * inv;
            } else {
                img[i] = img[i + 1] = img[i + 2] = 0; img[i + 3] = 0;
            }
        }
    }
    return img;
}

function toBytes(img, w, h) {
    const out = Buffer.alloc(w * h * 4);
    for (let i = 0; i < w * h; i++) {
        out[i * 4] = Math.round(clamp01(img[i * 4]) * 255);
        out[i * 4 + 1] = Math.round(clamp01(img[i * 4 + 1]) * 255);
        out[i * 4 + 2] = Math.round(clamp01(img[i * 4 + 2]) * 255);
        out[i * 4 + 3] = Math.round(clamp01(img[i * 4 + 3]) * 255);
    }
    return out;
}

// ---------------------------------------------------------------------------
// TGA writer: uncompressed true-colour, 32 bpp, BGRA, top-left origin.
// Header (18 bytes):
//   0  idLength        0
//   1  colorMapType    0
//   2  imageType       2   (uncompressed true-colour)
//   3-7 colour map spec  0
//   8-9  xOrigin       0
//   10-11 yOrigin      0
//   12-13 width        LE
//   14-15 height       LE
//   16 pixelDepth      32
//   17 imageDescriptor 0x28  (bits 0-3: 8 alpha bits; bit 5: top-left origin)
// ---------------------------------------------------------------------------

function writeTGA(file, rgba, w, h) {
    const hdr = Buffer.alloc(18, 0);
    hdr[2] = 2;
    hdr.writeUInt16LE(w, 12);
    hdr.writeUInt16LE(h, 14);
    hdr[16] = 32;
    hdr[17] = 0x28;
    const body = Buffer.alloc(w * h * 4);
    for (let i = 0; i < w * h; i++) {
        body[i * 4] = rgba[i * 4 + 2];      // B
        body[i * 4 + 1] = rgba[i * 4 + 1];  // G
        body[i * 4 + 2] = rgba[i * 4];      // R
        body[i * 4 + 3] = rgba[i * 4 + 3];  // A
    }
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, Buffer.concat([hdr, body]));
}

// ---------------------------------------------------------------------------
// Minimal PNG writer (RGBA8, filter 0 on every row)
// ---------------------------------------------------------------------------

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
    ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
    const raw = Buffer.alloc((w * 4 + 1) * h);
    for (let y = 0; y < h; y++) {
        raw[y * (w * 4 + 1)] = 0;
        rgba.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
    }
    const idat = zlib.deflateSync(raw, { level: 9 });
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, Buffer.concat([sig, chunk("IHDR", ihdr), chunk("IDAT", idat), chunk("IEND", Buffer.alloc(0))]));
}

// ---------------------------------------------------------------------------
// Context preview: icon at 20px on a fake minimap, scaled up 4x so it can be
// judged by eye (the 4x upscale is nearest-neighbour on purpose, so what you
// see is the real 20px pixel grid).
// ---------------------------------------------------------------------------

function downsample(rgba, w, h, tw, th) {
    // box filter, premultiplied
    const out = new Float32Array(tw * th * 4);
    for (let y = 0; y < th; y++) {
        for (let x = 0; x < tw; x++) {
            const x0 = Math.floor(x * w / tw), x1 = Math.max(x0 + 1, Math.floor((x + 1) * w / tw));
            const y0 = Math.floor(y * h / th), y1 = Math.max(y0 + 1, Math.floor((y + 1) * h / th));
            let r = 0, g = 0, b = 0, a = 0, n = 0;
            for (let yy = y0; yy < y1; yy++) for (let xx = x0; xx < x1; xx++) {
                const i = (yy * w + xx) * 4;
                const al = rgba[i + 3] / 255;
                r += rgba[i] / 255 * al; g += rgba[i + 1] / 255 * al; b += rgba[i + 2] / 255 * al; a += al; n++;
            }
            const o = (y * tw + x) * 4;
            if (a > 0) { out[o] = r / a; out[o + 1] = g / a; out[o + 2] = b / a; out[o + 3] = a / n; }
        }
    }
    return out;
}

function contextPreview(rgba) {
    const W = 256, H = 256, SCALE = 4, ICON = 20;
    const small = downsample(rgba, SIZE, SIZE, ICON, ICON);
    const canvas = new Float32Array(W * H * 4);
    const cx = W / 2, cy = H / 2;
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
        const o = (y * W + x) * 4;
        // background: dark UI grey
        let col = [0.10, 0.10, 0.11, 1];
        const d = Math.hypot(x - cx, y - cy);
        // fake minimap disc + tracking-border-ish ring at 4x scale
        const mapR = 100, ringR = 52 * SCALE / 4 * 1.0;
        if (d < mapR) col = [0.22, 0.26, 0.20, 1];             // greenish terrain
        // tracking border ring: ~53px overlay around a 20px icon => ring outer ~ 26px radius at 1x
        const ringOuter = 13 * SCALE, ringInner = 10.5 * SCALE;
        if (d < ringOuter && d > ringInner) {
            const t = (d - ringInner) / (ringOuter - ringInner);
            const shade = 0.55 + 0.35 * Math.sin(t * Math.PI);
            col = [shade * 0.85, shade * 0.72, shade * 0.45, 1]; // brass-ish
        }
        // dark background disc under the icon (matches UI-Minimap-Background tinted)
        if (d <= ringInner) col = [0.12, 0.05, 0.18, 1];
        canvas[o] = col[0]; canvas[o + 1] = col[1]; canvas[o + 2] = col[2]; canvas[o + 3] = 1;
        void ringR;
    }
    // blit the 20px icon at 4x nearest-neighbour, centred
    const ox = cx - ICON * SCALE / 2, oy = cy - ICON * SCALE / 2;
    for (let y = 0; y < ICON * SCALE; y++) for (let x = 0; x < ICON * SCALE; x++) {
        const sx = Math.floor(x / SCALE), sy = Math.floor(y / SCALE);
        const si = (sy * ICON + sx) * 4;
        const src = [small[si], small[si + 1], small[si + 2], small[si + 3]];
        const px = Math.round(ox + x), py = Math.round(oy + y);
        if (px < 0 || py < 0 || px >= W || py >= H) continue;
        const o = (py * W + px) * 4;
        const dst = [canvas[o], canvas[o + 1], canvas[o + 2], canvas[o + 3]];
        const res = over(dst, src);
        canvas[o] = res[0]; canvas[o + 1] = res[1]; canvas[o + 2] = res[2]; canvas[o + 3] = res[3];
    }
    // also a true 1x copy in the top-left corner so the real size is visible too
    for (let y = 0; y < ICON; y++) for (let x = 0; x < ICON; x++) {
        const si = (y * ICON + x) * 4;
        const src = [small[si], small[si + 1], small[si + 2], small[si + 3]];
        const px = 12 + x, py = 12 + y;
        const o = (py * W + px) * 4;
        const dst = [canvas[o], canvas[o + 1], canvas[o + 2], canvas[o + 3]];
        const res = over(dst, src);
        canvas[o] = res[0]; canvas[o + 1] = res[1]; canvas[o + 2] = res[2]; canvas[o + 3] = res[3];
    }
    return toBytes(canvas, W, H);
}

// ---------------------------------------------------------------------------

const img = render();
const rgba = toBytes(img, SIZE, SIZE);
writeTGA(OUT_TGA, rgba, SIZE, SIZE);
writePNG(OUT_PNG, rgba, SIZE, SIZE);
writePNG(OUT_CTX, contextPreview(rgba), 256, 256);
console.log("wrote", OUT_TGA);
console.log("wrote", OUT_PNG);
console.log("wrote", OUT_CTX);
