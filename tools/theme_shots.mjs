#!/usr/bin/env node
// A picture of a page of examples/whatsnew in every palette of ui.NAMED_PALETTES, with no window (--headless, WARP): to look
// at what a change of colours does in all of them. By default the find page, searching "the".
//   node tools/theme_shots.mjs [--build] [--out folder] [--page name] [--find text] [--only name[,name]]
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const { values: opt } = parseArgs({ options: {
  build: { type: 'boolean' }, out: { type: 'string', default: join(repo, 'build', 'theme_shots') },
  page: { type: 'string', default: 'Find' }, find: { type: 'string', default: 'the' }, only: { type: 'string' },
} })
const windows = process.platform === 'win32'
const exe = join(repo, 'build', 'whatsnew' + (windows ? '.exe' : ''))
const PORT = '9393'
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const cdp = (...a) => spawnSync(process.execPath, [join(repo, 'tools', 'cdp.mjs'), '--port', PORT, ...a], { encoding: 'utf8' })
const must = (...a) => {
  const r = cdp(...a)
  if (r.status !== 0) throw new Error(`cdp ${a.join(' ')}: ${r.stderr || r.stdout}`)
  return r.stdout
}

if (opt.build) {
  const r = windows
    ? spawnSync('cmd.exe', ['/c', '.\\build.bat', 'whatsnew'], { cwd: repo, stdio: 'inherit' })
    : spawnSync('odin', ['build', 'examples/whatsnew', `-out:${exe}`, '-o:speed', '-vet'], { cwd: repo, stdio: 'inherit' })
  if (r.status !== 0) process.exit(1)
}
if (!existsSync(exe)) throw new Error(`${exe} is missing: run with --build`)
mkdirSync(opt.out, { recursive: true })

// The names, from the source: one list of them, the toolkit's.
const source = readFileSync(join(repo, 'ui', 'theme_default.odin'), 'utf8')
const list = source.slice(source.indexOf('NAMED_PALETTES :='))
const names = [...list.slice(0, list.indexOf('\n}')).matchAll(/\{"([^"]+)", PALETTE_/g)].map((m) => m[1])
  .filter((n) => !opt.only || opt.only.split(',').includes(n))

for (const name of names) {
  const child = spawn(exe, ['--headless', `--page=${opt.page}`, `--palette=${name}`], { env: { ...process.env, TOOLKIT_DEVTOOLS: PORT }, stdio: 'ignore' })
  try {
    for (let i = 0; cdp('state').status !== 0; i++) {
      if (child.exitCode !== null) throw new Error(`whatsnew ended (${child.exitCode})`)
      if (i > 100) throw new Error('no answer')
      await sleep(100)
    }
    must('idle')
    if (opt.find) {
      must('key', 'ctrl+f')
      must('type', opt.find)
      must('idle')
    }
    must('shot', join(opt.out, name.replaceAll(' ', '_') + '.png'))
    console.log('saved', name)
  } finally {
    child.kill()
    await new Promise((r) => (child.exitCode !== null ? r() : child.once('exit', r)))
  }
}
