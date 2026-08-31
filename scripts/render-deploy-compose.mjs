#!/usr/bin/env node
// ── Proxima — deploy compose generator ──────────────────────────────
//
// Renders docker-compose.backend.yml / docker-compose.frontend.yml in
// this repo FROM the composes that the Proxima-Backend and
// Proxima-Frontend repos actually run.
//
// Why generate instead of maintaining a second copy: the two files had
// silently diverged into different topologies. The deploy stack was
// missing infisical + infisical-bootstrap entirely, and because
// src/services/secret_resolver.py has no local fallback, a deployment
// from those files could not store a Proxmox credential at all -- it
// saved the server row, then failed on the secret write and left the
// resource tree empty. A generated file cannot drift like that.
//
// The transform is deliberately LINE-BASED rather than a YAML
// round-trip: these composes carry a great deal of hard-won commentary
// (PVE quirks, mTLS ordering, arm64 traps) and a parse/re-emit cycle
// would throw all of it away and produce an unreviewable diff.
//
// Two rules, and that is the whole transform:
//   1. `build: <ctx>` lines (and their nested block form) are dropped.
//   2. `image: proxima-<name>:${PROXIMA_VERSION:-latest}` becomes
//      `image: ${REGISTRY_HOST:-...}/proxima-<name>/app:${IMAGE_TAG:-latest}`.
//
// Each target also gets a header comment block from scripts/overlay/
// (Portainer instructions, the variable table). If a deployment ever
// needs a service the source compose has no reason to carry, it goes
// in an `<name>.extra.yml` overlay there and is spliced into the
// matching top-level section — see parseOverlay/spliceSection below.
// Keeping such things in files rather than in this script's logic is
// what stops the generator from slowly re-acquiring the special cases
// it was written to remove. There are currently no extras: the update
// sidecar was removed from the product (it mounted the Docker socket
// beside the credential store), so both stacks are notify-only.
//
// Usage:
//   node scripts/render-deploy-compose.mjs           # write the files
//   node scripts/render-deploy-compose.mjs --check   # CI: fail on drift
//
// NB: no regular expressions anywhere -- repo-wide ban (CLAUDE.md).
// All matching here is startsWith / indexOf / slice on explicit
// substrings, the same way the frontend stack's awk index() hook works.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..");
const SIBLINGS = resolve(REPO, "..");

const REGISTRY = "${REGISTRY_HOST:-updates.dev-proxima.com}";
const TAG = "${IMAGE_TAG:-latest}";
const VERSION_SUFFIX = ":${PROXIMA_VERSION:-latest}";

const TARGETS = [
  {
    name: "backend",
    src: join(SIBLINGS, "Proxima-Backend", "docker-compose.yml"),
    out: join(REPO, "docker-compose.backend.yml"),
    overlay: join(HERE, "overlay", "backend.extra.yml"),
    header: join(HERE, "overlay", "backend.header.txt"),
  },
  {
    name: "frontend",
    src: join(SIBLINGS, "Proxima-Frontend", "docker-compose.yml"),
    out: join(REPO, "docker-compose.frontend.yml"),
    overlay: join(HERE, "overlay", "frontend.extra.yml"),
    header: join(HERE, "overlay", "frontend.header.txt"),
  },
];

const BANNER = [
  "# ╔═════════════════════════════════════════════════════════════════╗",
  "# ║  GENERATED FILE — DO NOT EDIT BY HAND                           ║",
  "# ║                                                                 ║",
  "# ║  Rendered by scripts/render-deploy-compose.mjs from the compose ║",
  "# ║  the source repo actually runs. Hand edits are overwritten on   ║",
  "# ║  the next render and fail CI's drift check in the meantime.     ║",
  "# ║                                                                 ║",
  "# ║  To change this file, change the SOURCE compose, then re-run:   ║",
  "# ║      node scripts/render-deploy-compose.mjs                     ║",
  "# ║                                                                 ║",
  "# ║  The header comment above the services comes from              ║",
  "# ║  scripts/overlay/, which is also where any deployment-only     ║",
  "# ║  service would be spliced in from.                             ║",
  "# ╚═════════════════════════════════════════════════════════════════╝",
  "",
];

// ── line helpers ────────────────────────────────────────────────────

function indentOf(line) {
  let n = 0;
  while (n < line.length && line[n] === " ") n += 1;
  return n;
}

function isBlank(line) {
  return line.trim().length === 0;
}

// A top-level YAML key: column 0, not a comment, and carrying a colon.
// `x-security-env: &security-env` counts, which is what we want -- it
// is a section boundary for splicing purposes like any other.
function isTopLevelKey(line) {
  if (line.length === 0) return false;
  if (line[0] === " " || line[0] === "#" || line[0] === "-") return false;
  return line.indexOf(":") !== -1;
}

function topLevelKeyName(line) {
  return line.slice(0, line.indexOf(":")).trim();
}

// ── rule 1: drop `build:` ───────────────────────────────────────────
//
// Two shapes in the wild:
//     build: .                       -- one line
//     build:                         -- block, followed by deeper lines
//       context: .
//       args:
//         VITE_APP_VERSION: ...
// Returns the index to resume from.
function skipBuild(lines, i) {
  const base = indentOf(lines[i]);
  const value = lines[i].trim().slice("build:".length).trim();
  let j = i + 1;
  if (value.length === 0) {
    // Block form: swallow every following line indented deeper than
    // the `build:` key itself. Blank lines inside the block are kept
    // with it (they belong to the block, not to the next key).
    while (j < lines.length) {
      if (isBlank(lines[j])) {
        let k = j;
        while (k < lines.length && isBlank(lines[k])) k += 1;
        if (k < lines.length && indentOf(lines[k]) > base) {
          j = k;
          continue;
        }
        break;
      }
      if (indentOf(lines[j]) <= base) break;
      j += 1;
    }
  }
  return j;
}

// ── rule 2: local image name -> registry reference ──────────────────
//
// `    image: proxima-backend-nginx:${PROXIMA_VERSION:-latest}`
//   becomes
// `    image: ${REGISTRY_HOST:-...}/proxima-backend-nginx/app:${IMAGE_TAG:-latest}`
//
// Only rewrites images Proxima itself publishes. Third-party pins
// (postgres:18-alpine, infisical/infisical:v0.159.25, ...) are left
// exactly as they are -- every one of them is already a multi-arch
// manifest list, so a single tag resolves correctly on amd64 and arm64
// alike and no `platform:` key is ever needed.
function rewriteImage(line) {
  const trimmed = line.trim();
  const KEY = "image: ";
  if (!trimmed.startsWith(KEY)) return null;
  const ref = trimmed.slice(KEY.length).trim();
  if (!ref.startsWith("proxima-")) return null;
  if (!ref.endsWith(VERSION_SUFFIX)) return null;
  const name = ref.slice(0, ref.length - VERSION_SUFFIX.length);
  if (name.indexOf("/") !== -1) return null; // already a registry ref
  const pad = " ".repeat(indentOf(line));
  return `${pad}image: ${REGISTRY}/${name}/app:${TAG}`;
}

// ── overlay splicing ────────────────────────────────────────────────
//
// An overlay file is a sequence of blocks introduced by a marker:
//     # ---8<--- services
//     <lines to append to the end of the `services:` section>
//     # ---8<--- volumes
//     <lines to append to the end of the `volumes:` section>
const MARKER = "# ---8<---";

function parseOverlay(text) {
  const blocks = new Map();
  let current = null;
  for (const line of text.split("\n")) {
    if (line.trim().startsWith(MARKER)) {
      current = line.trim().slice(MARKER.length).trim();
      if (!blocks.has(current)) blocks.set(current, []);
      continue;
    }
    if (current !== null) blocks.get(current).push(line);
  }
  // Trim trailing blank lines per block so splices stay tidy.
  for (const [key, lines] of blocks) {
    while (lines.length > 0 && isBlank(lines[lines.length - 1])) lines.pop();
    blocks.set(key, lines);
  }
  return blocks;
}

// Append `block` at the end of top-level section `section`, i.e. just
// before the next top-level key (or EOF). Trailing blank lines inside
// the section are kept AFTER the splice so the file keeps its rhythm.
function spliceSection(lines, section, block) {
  let start = -1;
  for (let i = 0; i < lines.length; i += 1) {
    if (isTopLevelKey(lines[i]) && topLevelKeyName(lines[i]) === section) {
      start = i;
      break;
    }
  }
  if (start === -1) {
    throw new Error(`overlay targets section '${section}', which the source compose does not have`);
  }
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i += 1) {
    if (isTopLevelKey(lines[i])) {
      end = i;
      break;
    }
  }
  while (end > start + 1 && isBlank(lines[end - 1])) end -= 1;
  return [...lines.slice(0, end), "", ...block, ...lines.slice(end)];
}

// ── render one target ───────────────────────────────────────────────

function render(target) {
  if (!existsSync(target.src)) {
    throw new Error(
      `source compose not found: ${target.src}\n` +
        `Expected the Proxima repos to be siblings under ${SIBLINGS}. ` +
        `Pass --siblings <dir> or check out the source repo there.`,
    );
  }
  // Normalise to LF. The sources are edited on Windows and are wholly CRLF,
  // and splitting on "\n" alone leaves a trailing "\r" on every line, which
  // the rejoin then preserves. These files are deployment artefacts for Linux
  // hosts and get pasted into Portainer, so they should be LF: it keeps diffs
  // against a stored stack meaningful, and keeps the embedded shell (the
  // db-init heredoc, the gateway entrypoint) out of the class of bugs where a
  // "SQL\r" terminator never matches "SQL". YAML block scalars normalise line
  // breaks so CRLF happens to survive today -- that is luck, not a guarantee.
  const srcLines = readFileSync(target.src, "utf8")
    .split("\n")
    .map((line) => (line.endsWith("\r") ? line.slice(0, -1) : line));

  const out = [];
  let i = 0;
  while (i < srcLines.length) {
    const line = srcLines[i];
    if (line.trim().startsWith("build:")) {
      i = skipBuild(srcLines, i);
      continue;
    }
    const rewritten = rewriteImage(line);
    out.push(rewritten === null ? line : rewritten);
    i += 1;
  }

  let lines = out;
  if (existsSync(target.overlay)) {
    const blocks = parseOverlay(readFileSync(target.overlay, "utf8"));
    for (const [section, block] of blocks) {
      if (block.length === 0) continue;
      lines = spliceSection(lines, section, block);
    }
  }

  const header = existsSync(target.header)
    ? readFileSync(target.header, "utf8").split("\n")
    : [];

  while (lines.length > 0 && isBlank(lines[lines.length - 1])) lines.pop();
  return [...BANNER, ...header, ...lines, ""].join("\n");
}

// ── main ────────────────────────────────────────────────────────────

const check = process.argv.includes("--check");
let drifted = 0;

for (const target of TARGETS) {
  const rendered = render(target);
  const existing = existsSync(target.out) ? readFileSync(target.out, "utf8") : null;

  if (check) {
    if (existing !== rendered) {
      drifted += 1;
      console.error(`DRIFT  ${target.out}`);
      const a = existing === null ? [] : existing.split("\n");
      const b = rendered.split("\n");
      let shown = 0;
      for (let i = 0; i < Math.max(a.length, b.length) && shown < 20; i += 1) {
        if (a[i] !== b[i]) {
          if (a[i] !== undefined) console.error(`  -${a[i]}`);
          if (b[i] !== undefined) console.error(`  +${b[i]}`);
          shown += 1;
        }
      }
      if (shown >= 20) console.error("  ... (truncated)");
    } else {
      console.log(`ok     ${target.out}`);
    }
    continue;
  }

  if (existing === rendered) {
    console.log(`unchanged  ${target.out}`);
  } else {
    writeFileSync(target.out, rendered, "utf8");
    console.log(`rendered   ${target.out}`);
  }
}

if (check && drifted > 0) {
  console.error("");
  console.error(
    `${drifted} deploy compose file(s) are out of date. ` +
      `Run: node scripts/render-deploy-compose.mjs`,
  );
  process.exit(1);
}
