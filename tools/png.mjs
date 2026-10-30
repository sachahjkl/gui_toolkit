// PNG for tests/e2e and timelines: 8-bit RGBA, no package.
import { promisify } from 'node:util'
import { deflate, deflateSync, inflateSync } from 'node:zlib'

const deflateAsync = promisify(deflate)

export function decodePng(buf) {
  let p = 8, width = 0, height = 0
  const idat = []
  while (p < buf.length) {
    const len = buf.readUInt32BE(p)
    const type = buf.toString('latin1', p + 4, p + 8)
    const data = buf.subarray(p + 8, p + 8 + len)
    if (type === 'IHDR') {
      width = data.readUInt32BE(0); height = data.readUInt32BE(4)
      if (data[8] !== 8 || data[9] !== 6) throw new Error('only 8-bit RGBA')
    }
    if (type === 'IDAT') idat.push(data)
    p += 12 + len
  }
  const raw = inflateSync(Buffer.concat(idat))
  const stride = width * 4
  const px = Buffer.alloc(stride * height)
  for (let y = 0; y < height; y++) {
    const f = raw[y * (stride + 1)]
    const line = y * (stride + 1) + 1
    for (let x = 0; x < stride; x++) {
      const a = x >= 4 ? px[y * stride + x - 4] : 0
      const b = y > 0 ? px[(y - 1) * stride + x] : 0
      const c = x >= 4 && y > 0 ? px[(y - 1) * stride + x - 4] : 0
      let v = raw[line + x]
      switch (f) {
        case 1: v += a; break
        case 2: v += b; break
        case 3: v += (a + b) >> 1; break
        case 4: {
          const q = a + b - c, pa = Math.abs(q - a), pb = Math.abs(q - b), pc = Math.abs(q - c)
          v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c
          break
        }
      }
      px[y * stride + x] = v & 255
    }
  }
  return { width, height, px }
}

const CRC = new Int32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c })
const crc32 = (b) => { let c = -1; for (const x of b) c = CRC[(c ^ x) & 255] ^ (c >>> 8); return (c ^ -1) >>> 0 }

function chunk(type, data) {
  const head = Buffer.alloc(8)
  head.writeUInt32BE(data.length, 0)
  head.write(type, 4, 'latin1')
  const tail = Buffer.alloc(4)
  tail.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])), 0)
  return Buffer.concat([head, data, tail])
}

// Each row filtered with Sub: an interface's flat areas become zeros.
function filtered(px, width, height) {
  const stride = width * 4
  const raw = Buffer.alloc((stride + 1) * height)
  for (let y = 0; y < height; y++) {
    const o = y * (stride + 1), s = y * stride
    raw[o] = 1
    for (let x = 0; x < stride; x++) raw[o + 1 + x] = px[s + x] - (x >= 4 ? px[s + x - 4] : 0)
  }
  return raw
}

function wrap(z, width, height) {
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4)
  ihdr[8] = 8; ihdr[9] = 6
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', z), chunk('IEND', Buffer.alloc(0))])
}

export function encodePng(px, width, height) { return wrap(deflateSync(filtered(px, width, height)), width, height) }

// On the threads of Node's pool: several pictures at once.
export async function encodePngAsync(px, width, height) { return wrap(await deflateAsync(filtered(px, width, height), { level: 9 }), width, height) }

// The share of the pixels that differ by more than `delta` on a channel, and an image of where (red).
export function compare(a, b, delta) {
  if (a.width !== b.width || a.height !== b.height) return { sizeDiffers: true }
  const { width, height } = a
  const diff = Buffer.alloc(width * height * 4)
  let n = 0
  for (let i = 0; i < a.px.length; i += 4) {
    const d = Math.max(Math.abs(a.px[i] - b.px[i]), Math.abs(a.px[i + 1] - b.px[i + 1]), Math.abs(a.px[i + 2] - b.px[i + 2]))
    if (d > delta) { n++; diff[i] = 255; diff[i + 3] = 255 } else { diff[i] = diff[i + 1] = diff[i + 2] = a.px[i + 1] >> 2; diff[i + 3] = 255 }
  }
  return { share: n / (width * height), diff, width, height }
}
