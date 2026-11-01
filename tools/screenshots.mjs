#!/usr/bin/env node
// Regenerates docs/screenshots/*.png, and the copies of them in site/img, from the examples, over the Chrome DevTools
// Protocol (tools/cdp.mjs): the picture is the frame the program rendered, so the mouse, the keyboard and the windows in
// front are left alone. Each program runs with an empty settings folder: the user's settings are neither read nor changed.
//   node tools/screenshots.mjs [--build] [--only name[,name]] [--width px]
//     --build   builds the examples first
//     --only    just these pictures
//     --width   the width of the pictures (default 1400; 0: as rendered)
import { spawn, spawnSync } from 'node:child_process'
import { copyFileSync, existsSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const { values: opt } = parseArgs({ options: { build: { type: 'boolean' }, only: { type: 'string' }, width: { type: 'string', default: '1400' } } })
const only = opt.only ? opt.only.split(',') : null
const width = Number(opt.width)
const PORT = 9390
const windows = process.platform === 'win32'

// What each picture shows: the program, its arguments, how long its animations are given.
const SHOTS = [
  { name: 'controls',   ex: 'fidget', args: ['--page=0', '--anim=on'], ms: 1500 },
  { name: 'inputs',     ex: 'fidget', args: ['--page=1', '--anim=on'], ms: 1500 },
  { name: 'data',       ex: 'fidget', args: ['--page=2', '--anim=on'], ms: 1500 },
  { name: 'playground', ex: 'fidget', args: ['--page=3', '--anim=on'], ms: 3200 },
  { name: 'palette',    ex: 'fidget', args: ['--palette_query=theme', '--theme=3', '--anim=on'], ms: 1500 },
  { name: 'settings',   ex: 'fidget', args: ['--settings', '--anim=on'], ms: 1500 },
  { name: 'toasts',     ex: 'fidget', args: ['--page=2', '--toasts', '--toast_pos=2', '--anim=on'], ms: 1800 },
  { name: 'about',      ex: 'fidget', args: ['--about', '--theme=4', '--anim=on'], ms: 1500 },
  { name: 'light',      ex: 'fidget', args: ['--page=0', '--theme=2', '--anim=on'], ms: 1500 },
  { name: 'bootstrap',  ex: 'fidget', args: ['--page=0', '--theme=7', '--anim=on'], ms: 1500 },
  { name: 'compact',    ex: 'fidget', args: ['--page=2', '--compact', '--anim=on'], ms: 1500 },
  { name: 'todo',       ex: 'todo',   args: [], ms: 1500 },
  { name: 'transforms', ex: 'transforms', args: ['--time=2.0'], ms: 1500 },
  { name: 'effects',    ex: 'effects',    args: ['--time=2.0'], ms: 1500 },
].filter((s) => !only || only.includes(s.name))

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const cdp = (...cmd) => spawnSync(process.execPath, [join(repo, 'tools', 'cdp.mjs'), '--port', String(PORT), ...cmd], { encoding: 'utf8' })

if (opt.build) {
  for (const ex of new Set(SHOTS.map((s) => s.ex))) {
    console.log('build', ex)
    const r = windows
      ? spawnSync('cmd.exe', ['/c', '.\\build.bat', ex], { cwd: repo, stdio: 'inherit' })
      : spawnSync('odin', ['build', `examples/${ex}`, `-out:build/${ex}`, '-o:speed', '-vet'], { cwd: repo, stdio: 'inherit' })
    if (r.status !== 0) process.exit(1)
  }
}

// Scaled to `px` wide, with the system's own tools.
function resize(file, px) {
  if (!px) return
  if (!windows) {
    const r = spawnSync('magick', [file, '-resize', `${px}x`, file], { stdio: 'inherit' })
    if (r.status !== 0) console.warn(`  not resized (ImageMagick): ${basename(file)}`)
    return
  }
  const script = `Add-Type -AssemblyName System.Drawing
$i = [Drawing.Image]::FromFile($env:SHOT_FILE); $w = [int]$env:SHOT_WIDTH
if ($i.Width -gt $w) {
  $h = [int][Math]::Round($i.Height * $w / $i.Width)
  $o = New-Object Drawing.Bitmap $w, $h, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [Drawing.Graphics]::FromImage($o); $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'
  $g.DrawImage($i, 0, 0, $w, $h); $g.Dispose(); $i.Dispose(); $o.Save($env:SHOT_FILE); $o.Dispose()
} else { $i.Dispose() }`
  const r = spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-Command', script], { env: { ...process.env, SHOT_FILE: file, SHOT_WIDTH: String(px) }, stdio: 'inherit' })
  if (r.status !== 0) throw new Error(`resize failed: ${file}`)
}

async function capture(shot) {
  const exe = join(repo, 'build', shot.ex + (windows ? '.exe' : ''))
  if (!existsSync(exe)) throw new Error(`${exe} is missing: run with --build`)
  const settings = mkdtempSync(join(tmpdir(), 'gui_toolkit_shot_'))
  const env = { ...process.env, TOOLKIT_DEVTOOLS: String(PORT), APPDATA: settings, XDG_CONFIG_HOME: settings }
  const child = spawn(exe, shot.args, { env, stdio: 'ignore', cwd: dirname(exe) })
  try {
    for (let i = 0; ; i++) {
      if (cdp('raw', 'Browser.getVersion').status === 0) break   // (transforms and effects have no box tree)
      if (i > 100) throw new Error(`${shot.ex} does not answer on port ${PORT}`)
      await sleep(100)
    }
    await sleep(shot.ms)
    const out = join(repo, 'docs', 'screenshots', shot.name + '.png')
    const r = cdp('shot', out)
    if (r.status !== 0) throw new Error(`${shot.name}: ${r.stderr}`)
    resize(out, width)
    const site = join(repo, 'site', 'img', shot.name + '.png')
    if (existsSync(site)) copyFileSync(out, site)
    console.log('saved', shot.name)
  } finally {
    child.kill()
    await new Promise((r) => (child.exitCode !== null ? r() : child.once('exit', r)))
    rmSync(settings, { recursive: true, force: true })
  }
}

for (const shot of SHOTS) await capture(shot)
