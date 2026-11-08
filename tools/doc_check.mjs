#!/usr/bin/env node
// What the documentation names must exist: the files and folders it cites, the command line flags and -define: it gives, and
// the identifiers of a package (`ui.something`). A name it cannot place is printed with its file and line; exit code 1 if any.
// It says nothing of whether a sentence is true, only that what it names is there.
//   node tools/doc_check.mjs [--root folder] [--extra folder]     --extra: also look for names in that folder (a submodule)
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

const { values: opt } = parseArgs({ options: { root: { type: 'string' }, extra: { type: 'string', multiple: true, default: [] } } })
const root = resolve(opt.root ?? join(dirname(fileURLToPath(import.meta.url)), '..'))
const files = (dir) => execFileSync('git', ['-C', dir, 'ls-files'], { encoding: 'utf8', maxBuffer: 1 << 28 }).split('\n').filter(Boolean)
const tracked = files(root)
const dirs = [root, ...opt.extra.map((d) => resolve(d))]

let code = ''
for (const dir of dirs) {
  for (const f of files(dir)) {
    if (!/\.(odin|mjs|js|ps1|sh|bat|rs|yml|toml|nix)$/.test(f) || /^(tests\/e2e\/baseline|font\/slug_ref)\//.test(f)) continue
    code += readFileSync(join(dir, f), 'utf8') + '\n'
  }
}
const inCode = (word) => code.includes(word)
const exists = (p) => dirs.some((d) => existsSync(join(d, p.replace(/[\\/]$/, '').replaceAll('\\', '/'))))
const PACKAGES = 'ui|draw|render|font|platform|config|arena|instance|testkit|i18n|fsx|flate|devtools'
const SYSTEM_FLAGS = /^--(recursive|init|locked|release|force|target-dir|no-verify)$/

const problems = []
const docs = tracked.filter((f) => /\.md$/.test(f) && !/^(CHANGELOG|changelog\.d\/|NOTICE|docs\/changes-)/.test(f) && !f.includes('/CHANGELOG') && !f.startsWith('ext/'))
if (tracked.includes('site/index.html')) docs.push('site/index.html')
for (const doc of docs) {
  readFileSync(join(root, doc), 'utf8').split(/\r?\n/).forEach((line, n) => {
    const say = (what) => problems.push(`${doc}:${n + 1}: ${what}`)
    const seen = new Set()
    const once = (what, ok) => { if (!seen.has(what)) { seen.add(what); if (!ok()) say(what) } }
    // links and cited paths
    for (const m of line.matchAll(/\]\(([^)#\s]+)(#[^)]*)?\)/g)) {
      const t = m[1]
      if (/^(https?:|mailto:)/.test(t)) continue
      const from = dirname(doc)
      once(`link ${t}`, () => existsSync(join(root, from, t)) || exists(t))
    }
    for (const m of line.matchAll(/(?<![\w./\\-])((?:tools|examples|tests|docs|src|native|res|assets|ui|draw|render|font|platform|devtools)[\\/][\w./\\-]*\w)/g)) {
      const p = m[1]
      if (/^[.*]*\*/.test(line.slice(m.index + p.length)) || !exists(p.split(/[\\/]/)[0])) continue   // (a pattern; a folder of the reader's project)
      // (docs/index.html is the page tk site_docs makes, the home page's link to the Docs section)
      once(`path ${p}`, () => exists(p) || exists(`${p}.exe`) || /^(tools|examples|tests|docs)[\\/]$/.test(p) || p === 'docs/index.html')
    }
    // flags, in code spans only
    for (const span of line.matchAll(/`([^`]+)`/g)) {
      for (const m of span[1].matchAll(/-define:([A-Z_]+)/g)) once(`define ${m[1]}`, () => inCode(m[1]))
      for (const m of span[1].matchAll(/(?<![\w-])(--[a-z][a-z_-]+)/g)) {
        if (!SYSTEM_FLAGS.test(m[1])) once(`flag ${m[1]}`, () => inCode(`"${m[1]}`) || inCode(`'${m[1]}`) || inCode(m[1].slice(2)))
      }
      for (const m of span[1].matchAll(new RegExp(`(?<![\\w.:])(${PACKAGES})\\.([a-zA-Z_][a-zA-Z_0-9]*)`, 'g'))) {
        if (/^(odin|md|mjs|exe|wgsl)$/.test(m[2]) || m[2].endsWith('_')) continue
        once(`name ${m[1]}.${m[2]}`, () => new RegExp(`\\b${m[2]}\\b`).test(code))
      }
    }
  })
}
for (const p of problems) console.log(p)
console.log(problems.length ? `${problems.length} names not found` : 'every name found')
process.exit(problems.length ? 1 : 0)
