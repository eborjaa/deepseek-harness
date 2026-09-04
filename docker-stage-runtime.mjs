#!/usr/bin/env node
/**
 * Stage the dsh runtime closure for the Synapse Docker image.
 *
 * This is a narrow port of the staging half of upstream's
 * scripts/build-exe-for-python-sdk.ts — `deployStaging()`, `restoreLegacyHoists()`
 * and `materializeStagedLinks()` — minus the @yao-pkg/pkg SEA packaging that the
 * Python wheel needs and a container does not. The deploy flags below are copied
 * from that script verbatim; keep them in sync if it changes.
 *
 * Why not just `pnpm deploy` in the Dockerfile: three separate things break.
 *
 *   1. node-linker=hoisted is required. This workspace has pervasive UNMET
 *      peerDependencies (`pnpm peers check`) that nothing declares; what
 *      satisfies them in a normal install is pnpm's hoisted fallback dir. An
 *      isolated layout drops that fallback and the runtime dies on whichever
 *      import it reaches first.
 *   2. pnpm's legacy hoister leaves some direct dependencies beside the deploy
 *      source rather than in the target — restoreLegacyHoists puts them back.
 *   3. `overrides` maps @deepseek-ai/cosmokit and schemastery to `link:vendor/*`.
 *      A link cannot survive into a self-contained tree, so every remaining
 *      symlink is dereferenced into real files.
 *
 * Package-local node_modules trees are deliberately not copied, preserving one
 * flat Cordis instance — the same reasoning upstream documents.
 */
import { spawnSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { cp, lstat, mkdir, readdir, readFile, realpath, rm } from 'node:fs/promises'
import { dirname, join, resolve, sep } from 'node:path'

const root = resolve(import.meta.dirname)
const DEPLOY_ROOT_PACKAGE = 'dsh-python-runtime-closure'
const DEPLOY_SOURCE_NODE_MODULES = 'python/sdk-runtime/node_modules'

const staging = process.argv[2]
if (!staging) {
  console.error('usage: node docker-stage-runtime.mjs <staging-dir>')
  process.exit(1)
}
if (staging === root || root.startsWith(staging + sep)) {
  throw new Error(`refusing to clear staging dir ${staging}: it contains the repo root.`)
}

function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, stdio: 'inherit' })
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} failed with ${String(result.status ?? result.signal)}`)
  }
}

/** Copy a package without its nested node_modules, dereferencing links. */
async function copyPackage(source, destination) {
  const nested = join(source, 'node_modules')
  await cp(source, destination, {
    recursive: true,
    dereference: true,
    filter: path => path !== nested && !path.startsWith(nested + sep),
  })
}

async function findSymlink(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name)
    const metadata = await lstat(path)
    if (metadata.isSymbolicLink()) return path
    if (metadata.isDirectory()) {
      const nested = await findSymlink(path)
      if (nested !== undefined) return nested
    }
  }
  return undefined
}

await rm(staging, { recursive: true, force: true })

run('pnpm', [
  '--filter',
  DEPLOY_ROOT_PACKAGE,
  'deploy',
  '--legacy',
  '--prod',
  '--config.node-linker=hoisted',
  '--config.auto-install-peers=false',
  '--config.link-workspace-packages=true',
  staging,
])

// 2. Restore direct dependencies the legacy hoister left beside the source.
const manifest = JSON.parse(await readFile(join(staging, 'package.json'), 'utf8'))
const sourceNodeModules = resolve(root, DEPLOY_SOURCE_NODE_MODULES)
const restored = []
for (const dependency of Object.keys(manifest.dependencies ?? {}).sort()) {
  const destination = join(staging, 'node_modules', dependency)
  if (existsSync(destination)) continue
  const source = join(sourceNodeModules, dependency)
  if (!existsSync(source)) {
    throw new Error(`deployed dependency ${dependency} is absent from both ${destination} and ${source}.`)
  }
  await mkdir(dirname(destination), { recursive: true })
  await copyPackage(source, destination)
  restored.push(dependency)
}
const stillMissing = Object.keys(manifest.dependencies ?? {})
  .filter(dependency => !existsSync(join(staging, 'node_modules', dependency)))
if (stillMissing.length > 0) {
  throw new Error(`staged dependencies remain missing: ${stillMissing.join(', ')}.`)
}
if (restored.length > 0) console.log(`stage-runtime: restored legacy deploy hoists: ${restored.join(', ')}`)

// 2b. Complete the closure for the WEB profile.
//
// Upstream's manifest describes the headless Python SDK runtime. This image
// runs `dsh web`, whose seeded profile loads the @deepseek-ai/dsh-base and
// @deepseek-ai/dsh-web-app bundles, and those pull plugins the SDK never
// needed (dsh-session-title-llm, reached via dsh-session-title-first-prompt-llm,
// is one). Rather than hand-maintaining that delta — a fork-local list that
// would silently rot against upstream — walk what is actually staged and pull
// in any `dependencies` entry that is missing, to a fixpoint. Sources come from
// the build stage's own installed tree, so nothing is resolved from the network.
const WEB_PROFILE_ROOTS = ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app']
const rootNodeModules = join(root, 'node_modules')
const stagedNodeModules = join(staging, 'node_modules')

async function readManifest(directory) {
  try {
    return JSON.parse(await readFile(join(directory, 'package.json'), 'utf8'))
  } catch {
    return undefined
  }
}

/**
 * Map every workspace package name to its directory. Under pnpm's isolated
 * linker a workspace package is NOT at node_modules/<name>; it lives at its
 * workspace path, and third-party packages sit in the hoisted fallback under
 * .pnpm/node_modules. Resolving only the first location silently finds nothing.
 */
const workspaceDirectories = ['vendor', 'apps', 'native/landlock-run/packages']
const workspacePackages = new Map()
async function indexWorkspace() {
  const candidates = []
  for (const relative of [...workspaceDirectories, 'packages']) {
    const base = join(root, relative)
    if (!existsSync(base)) continue
    for (const entry of await readdir(base, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue
      const path = join(base, entry.name)
      candidates.push(path)
      // packages/<group>/<pkg> is two levels deep.
      if (relative === 'packages') {
        for (const nested of await readdir(path, { withFileTypes: true })) {
          if (nested.isDirectory()) candidates.push(join(path, nested.name))
        }
      }
    }
  }
  for (const path of candidates) {
    const manifest = await readManifest(path)
    if (manifest?.name !== undefined) workspacePackages.set(manifest.name, path)
  }
}
await indexWorkspace()

/** Locate a package in the build stage: workspace path, direct, or hoisted. */
function resolveSource(name) {
  for (const candidate of [
    workspacePackages.get(name),
    join(rootNodeModules, name),
    join(rootNodeModules, '.pnpm', 'node_modules', name),
  ]) {
    if (candidate !== undefined && existsSync(candidate)) return candidate
  }
  return undefined
}

const unresolved = new Set()

/** Copy one package into staging from the build stage's installed tree. */
async function stagePackage(name) {
  const destination = join(stagedNodeModules, name)
  if (existsSync(destination)) return false
  const source = resolveSource(name)
  if (source === undefined) {
    unresolved.add(name)
    return false
  }
  await mkdir(dirname(destination), { recursive: true })
  await copyPackage(source, destination)
  return true
}

const added = []
for (const name of WEB_PROFILE_ROOTS) {
  if (await stagePackage(name)) added.push(name)
}

// Fixpoint: every staged package's runtime dependencies must themselves be staged.
let changed = true
while (changed) {
  changed = false
  const pending = [stagedNodeModules]
  const seen = new Set()
  while (pending.length > 0) {
    const directory = pending.pop()
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue
      // Scoped dirs (@scope) hold packages one level deeper.
      if (entry.name.startsWith('@')) {
        pending.push(join(directory, entry.name))
        continue
      }
      if (entry.name === 'node_modules' || entry.name === '.bin') continue
      const packageDirectory = join(directory, entry.name)
      if (seen.has(packageDirectory)) continue
      seen.add(packageDirectory)
      const manifest = await readManifest(packageDirectory)
      if (manifest === undefined) continue
      // Required peerDependencies count as runtime edges: this workspace leans
      // on them heavily and does NOT declare them as dependencies anywhere
      // (see `pnpm peers check`). dsh-session-title-first-prompt-llm reaching
      // dsh-session-title-llm is one such edge, and following only
      // `dependencies` misses it. Peers marked optional are skipped.
      const optionalPeers = manifest.peerDependenciesMeta ?? {}
      const requiredPeers = Object.keys(manifest.peerDependencies ?? {})
        .filter(peer => optionalPeers[peer]?.optional !== true)
      for (const dependency of [...Object.keys(manifest.dependencies ?? {}), ...requiredPeers]) {
        if (existsSync(join(stagedNodeModules, dependency))) continue
        if (await stagePackage(dependency)) {
          added.push(dependency)
          changed = true
        }
      }
    }
  }
}
if (added.length > 0) {
  console.log(`stage-runtime: completed web-profile closure (${added.length}): ${added.sort().join(', ')}`)
}
// Anything still unresolved is reported rather than swallowed: a silent skip
// here is exactly how this staging shipped a tree that died at runtime.
// Third-party packages absent from the prod install are expected (dev-only);
// a missing @deepseek-ai/* package is not, and fails the build.
if (unresolved.size > 0) {
  const workspaceMisses = [...unresolved].filter(name => name.startsWith('@deepseek-ai/')).sort()
  console.log(`stage-runtime: unresolved (not staged): ${[...unresolved].sort().join(', ')}`)
  if (workspaceMisses.length > 0) {
    throw new Error(`stage-runtime: workspace packages could not be located: ${workspaceMisses.join(', ')}`)
  }
}

// 3. Dereference every remaining symlink so the tree is self-contained.
const nodeModules = join(staging, 'node_modules')
let remaining = await findSymlink(nodeModules)
while (remaining !== undefined) {
  const segments = remaining.slice(nodeModules.length + 1).split(sep)
  const binIndex = segments.lastIndexOf('.bin')
  if (binIndex >= 0) {
    await rm(join(nodeModules, ...segments.slice(0, binIndex + 1)), { recursive: true, force: true })
    remaining = await findSymlink(nodeModules)
    continue
  }
  const source = await realpath(remaining)
  await rm(remaining, { recursive: true, force: true })
  await copyPackage(source, remaining)
  remaining = await findSymlink(nodeModules)
}

console.log(`stage-runtime: staged ${DEPLOY_ROOT_PACKAGE} into ${staging}`)
