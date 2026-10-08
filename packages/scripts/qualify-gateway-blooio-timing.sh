#!/usr/bin/env bash
set -euo pipefail
SOURCE_SHA=170188a4836365eb35816e674322173639650d3b
TASK_SOURCE="$1"
TASK_CAPSULE="$2"
TASK_EVIDENCE="$3"
test "$(git -C "$TASK_SOURCE" rev-parse HEAD)" = "$SOURCE_SHA"
test "$(bun --version)" = 1.4.2
test "$(node --version)" = v24.15.0
mkdir -p "$TASK_CAPSULE" "$TASK_EVIDENCE"
export TASK_SOURCE TASK_CAPSULE TASK_EVIDENCE
# Current Dockerfile-equivalent workspace pruning, with direct versions pinned to current public lock.
bun - <<'JS'
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const source=process.env.TASK_SOURCE,target=process.env.TASK_CAPSULE,evidence=process.env.TASK_EVIDENCE;
const lock=Bun.JSONC.parse(fs.readFileSync(path.join(source,'bun.lock'),'utf8'));
const entries=Object.values(lock.packages);const manifests={};
function copy(p){const dst=path.join(target,p);fs.mkdirSync(path.dirname(dst),{recursive:true});fs.cpSync(path.join(source,p),dst,{recursive:true});}
function exact(name,range){range=lock.overrides?.[name]??range;const valid=e=>Array.isArray(e)&&typeof e[0]==='string'&&e[0].startsWith(name+'@')&&Bun.semver.satisfies(e[0].slice(name.length+1),range);const primary=lock.packages[name];const candidates=entries.filter(valid);if(valid(primary))return primary[0].slice(name.length+1);const versions=[...new Set(candidates.map(e=>e[0].slice(name.length+1)))];if(versions.length===1)return versions[0];throw Error('LOCK_RESOLUTION_NOT_UNIQUE:'+name);}
for(const p of ['packages/cloud/services/gateway-webhook','packages/cloud/services/_common','packages/core','packages/cloud/sdk']){const m=JSON.parse(fs.readFileSync(path.join(source,p,'package.json'),'utf8'));manifests[p]=m;}
const originalService=structuredClone(manifests['packages/cloud/services/gateway-webhook']);
for(const p of ['packages/cloud/services/gateway-webhook/src','packages/cloud/services/gateway-webhook/__tests__/blooio-adapter.test.ts','packages/cloud/services/gateway-webhook/tsconfig.json','packages/cloud/services/_common/src','packages/cloud/sdk/src','packages/core/src/errors.ts','packages/core/src/security/log-redaction.ts','biome.json'])copy(p);
for(const p of ['packages/biome.json','packages/cloud/biome.json','packages/cloud/services/biome.json'])if(fs.existsSync(path.join(source,p)))copy(p);
for(const [p,m]of Object.entries(manifests)){delete m.devDependencies;if(p==='packages/core')manifests[p]={name:m.name,version:m.version,type:'module',exports:{'.':'./src/errors.ts','./errors':'./src/errors.ts','./protocol':'./src/protocol.ts','./security/log-redaction':'./src/security/log-redaction.ts'}};else for(const [name,range]of Object.entries(m.dependencies??{}))if(!range.startsWith('workspace:'))m.dependencies[name]=exact(name,range);}
fs.writeFileSync(path.join(target,'packages/core/src/protocol.ts'),'export * from "./errors.ts"; export * from "./security/log-redaction.ts";\n');
for(const [p,m]of Object.entries(manifests))fs.writeFileSync(path.join(target,p,'package.json'),JSON.stringify(m));
const tools={};for(const name of ['@biomejs/biome','typescript','@types/node','@types/hashring','bun-types'])tools[name]=exact(name,originalService.devDependencies[name]);
fs.writeFileSync(path.join(target,'package.json'),JSON.stringify({name:'gateway-public-qualification',private:true,workspaces:Object.keys(manifests),devDependencies:tools,overrides:Object.fromEntries(Object.entries(lock.overrides??{}).filter(([,value])=>!value.startsWith('workspace:')))}));
fs.writeFileSync(path.join(target,'bunfig.toml'),'[install]\nauto = "disable"\n');
fs.copyFileSync(path.join(source,'bun.lock'),path.join(evidence,'reviewed-public-source.bun.lock'));
fs.writeFileSync(path.join(evidence,'direct-version-pins.json'),JSON.stringify({tools,productionManifests:manifests},null,2));
JS
cd "$TASK_CAPSULE"
# Empty owned HOME/cache; no repository/provider/npm credentials or lifecycle scripts.
TASK_PUBLIC_HOME="$TASK_CAPSULE/.home"
mkdir -p "$TASK_PUBLIC_HOME"
timeout --kill-after=5s 120s env -i PATH="$PATH" HOME="$TASK_PUBLIC_HOME" CI=true BUN_INSTALL_CACHE_DIR="$TASK_PUBLIC_HOME/cache" bun install --ignore-scripts --registry=https://registry.npmjs.org > "$TASK_EVIDENCE/dependency-install.log" 2>&1
# Refuse any resolved version/SRI outside the reviewed current-public lock. No unrelated upgrade accepted.
bun - <<'JS'
const fs=require('node:fs'),path=require('node:path');
const original=Bun.JSONC.parse(fs.readFileSync(path.join(process.env.TASK_EVIDENCE,'reviewed-public-source.bun.lock'),'utf8'));
const installed=Bun.JSONC.parse(fs.readFileSync('bun.lock','utf8'));
const signature=e=>JSON.stringify([e[0],e.find(x=>typeof x==='string'&&/^sha(?:256|512)-/.test(x))]);
const allowed=new Set(Object.values(original.packages).map(signature));let checked=0;
for(const e of Object.values(installed.packages)){if(e[0].includes('@workspace:'))continue;if(!allowed.has(signature(e)))throw Error('UNREVIEWED_RESOLVED_VERSION_OR_SRI:'+e[0]);checked++;}
fs.writeFileSync(path.join(process.env.TASK_EVIDENCE,'resolved-dependency-proof.json'),JSON.stringify({checked,allVersionsAndSRIsInReviewedPublicLock:true}));
JS
check() {
  task_name="$1"; shift
  if timeout --kill-after=5s 120s "$@" > "$TASK_EVIDENCE/$task_name.log" 2>&1; then
    test "$(du -cb "$TASK_EVIDENCE/"*.log | tail -1 | cut -f1)" -le 1048576
  else
    task_exit=$?
    test "$(wc -c < "$TASK_EVIDENCE/$task_name.log")" -le 1048576
    tail -80 "$TASK_EVIDENCE/$task_name.log"
    exit "$task_exit"
  fi
}
# Formatter first, before any build/type/test work.
check changed-biome node_modules/.bin/biome check --vcs-enabled=false \
  packages/cloud/services/gateway-webhook/src/adapters/blooio.ts \
  packages/cloud/services/gateway-webhook/src/adapters/types.ts \
  packages/cloud/services/gateway-webhook/src/webhook-handler.ts \
  packages/cloud/services/gateway-webhook/__tests__/blooio-adapter.test.ts
TASK_RUNNER_PATH="$PATH"
export -f check
# No provider network fallback; real public Core/errors/protocol/log-redaction and SDK contract sources.
sudo -n unshare --net -- bash -c '
  set -euo pipefail
  ip link set lo up
  test "$(ip -o link show | wc -l)" -eq 1
  test -z "$(ip route show)"
  exec env -i PATH="$1" HOME="$2" CI=true NODE_ENV=test DO_NOT_TRACK=1 \
    WRANGLER_SEND_METRICS=false TURBO_TELEMETRY_DISABLED=1 \
    TASK_CAPSULE="$3" TASK_EVIDENCE="$4" bash -s
' _ "$TASK_RUNNER_PATH" "$TASK_PUBLIC_HOME" "$TASK_CAPSULE" "$TASK_EVIDENCE" <<'OFFLINE'
set -euo pipefail
cd "$TASK_CAPSULE"
check() {
  name="$1"; shift
  if timeout --kill-after=5s 120s "$@" > "$TASK_EVIDENCE/$name.log" 2>&1; then
    test "$(du -cb "$TASK_EVIDENCE/"*.log | tail -1 | cut -f1)" -le 1048576
  else
    status=$?;test "$(wc -c < "$TASK_EVIDENCE/$name.log")" -le 1048576;tail -80 "$TASK_EVIDENCE/$name.log";exit "$status"
  fi
}
cd packages/cloud/services/gateway-webhook
check owning-three bun --conditions=eliza-source test __tests__/blooio-adapter.test.ts --timeout 60000
grep -Eq '^[[:space:]]*3 pass[[:space:]]*$' "$TASK_EVIDENCE/owning-three.log"
grep -Eq '^[[:space:]]*0 fail[[:space:]]*$' "$TASK_EVIDENCE/owning-three.log"
check gateway-types ../../../../node_modules/.bin/tsc --noEmit --project tsconfig.json
check gateway-normal-build bun build src/index.ts --outdir dist --target node --conditions eliza-source
cp dist/index.js "$TASK_EVIDENCE/gateway-index.js"
sha256sum "$TASK_EVIDENCE/gateway-index.js" > "$TASK_EVIDENCE/gateway-sha256.txt"
OFFLINE
test "$(git -C "$TASK_SOURCE" rev-parse HEAD)" = "$SOURCE_SHA"
git -C "$TASK_SOURCE" diff --quiet HEAD
printf '%s\n' "$SOURCE_SHA" > "$TASK_EVIDENCE/source-commit.txt"
