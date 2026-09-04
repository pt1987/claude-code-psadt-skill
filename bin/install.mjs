#!/usr/bin/env node
/**
 * psadt-deploy-skill - installer for the psadt-deploy Claude Code skill.
 *
 *   npx psadt-deploy-skill                 install/update in ~/.claude/skills/psadt-deploy
 *   npx psadt-deploy-skill --project       install into ./.claude/skills/psadt-deploy instead
 *   npx psadt-deploy-skill --dir <path>    install into an explicit folder
 *   npx psadt-deploy-skill --ref <ref>     a branch or tag instead of main
 *   npx psadt-deploy-skill --no-setup      skip the setup doctor
 *
 * Design notes that matter:
 *
 * - Zero dependencies. Node 18 has global fetch, Windows ships bsdtar as tar.exe, and an installer that
 *   pulls in a dependency tree is an installer that can break for reasons unrelated to the skill.
 * - The package ships ONLY bin/. The skill itself comes from GitHub at install time, so a new skill
 *   version needs no npm republish - only a change to this file does.
 * - This script never writes the skill config. Resolving the config home is Get-PsadtConfig's job
 *   (explicit -SkillRoot > $env:PSADT_DEPLOY_HOME > %LOCALAPPDATA%\psadt-deploy), and a second
 *   implementation in JavaScript would drift from it. So it spawns Set-PsadtConfig.ps1 and
 *   Initialize-PsadtSkill.ps1 and lets them decide.
 */

import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const REPO = 'pt1987/claude-code-psadt-skill';
const SKILL_FOLDER = 'psadt-deploy';

// --- arguments ---------------------------------------------------------------------------------
const argv = process.argv.slice(2);
function flagValue(name) {
  const i = argv.indexOf(name);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : null;
}
const wantHelp = argv.includes('--help') || argv.includes('-h');
const ref = flagValue('--ref') || 'main';
const noSetup = argv.includes('--no-setup');
const explicitDir = flagValue('--dir');
const projectScope = argv.includes('--project');

if (wantHelp) {
  console.log(`psadt-deploy-skill - install the psadt-deploy Claude Code skill

  npx psadt-deploy-skill [--dir <path>] [--project] [--ref <branch|tag>] [--no-setup]

  --dir <path>   install into this folder
  --project      install into ./.claude/skills/${SKILL_FOLDER} (default is the user's ~/.claude/skills)
  --ref <ref>    branch or tag to install (default: main)
  --no-setup     do not run the setup doctor afterwards
`);
  process.exit(0);
}

const target = explicitDir
  ? resolve(explicitDir)
  : projectScope
    ? resolve(join(process.cwd(), '.claude', 'skills', SKILL_FOLDER))
    : resolve(join(homedir(), '.claude', 'skills', SKILL_FOLDER));

// --- small helpers -----------------------------------------------------------------------------
function run(exe, args, opts = {}) {
  return spawnSync(exe, args, { stdio: 'inherit', shell: false, ...opts });
}
function runCapture(exe, args) {
  return spawnSync(exe, args, { encoding: 'utf8', shell: false });
}
function has(exe) {
  const r = runCapture(exe, ['--version']);
  return !r.error && r.status === 0;
}
function fail(msg) {
  console.error(`\n  ERROR  ${msg}\n`);
  process.exit(1);
}

if (process.platform !== 'win32') {
  fail('This skill builds Windows Intune packages and needs Windows (PowerShell, IntuneWinAppUtil, PSADT).');
}

console.log(`\npsadt-deploy-skill\n  target : ${target}\n  ref    : ${ref}`);

// --- 1. get the skill --------------------------------------------------------------------------
// Order of preference: update an existing clone, else clone, else tarball. The tarball route exists
// because plenty of managed machines have no git at all.
const gitAvailable = has('git');
mkdirSync(target, { recursive: true });

if (existsSync(join(target, '.git'))) {
  if (!gitAvailable) fail(`${target} is a git clone but git is not available to update it.`);
  console.log('\n  updating the existing clone (git pull --ff-only)');
  const r = run('git', ['-C', target, 'pull', '--ff-only', 'origin', ref]);
  if (r.status !== 0) {
    fail('git pull --ff-only failed. Local changes in the skill folder? Commit or discard them, or install into a fresh folder with --dir.');
  }
} else if (gitAvailable) {
  console.log('\n  cloning (git clone --depth 1)');
  // Clone into a temp folder and move the contents, because git refuses a non-empty target.
  const stage = join(tmpdir(), `psadt-skill-${Date.now()}`);
  const r = run('git', ['clone', '--depth', '1', '--branch', ref, `https://github.com/${REPO}.git`, stage]);
  if (r.status !== 0) {
    fail(
      `git clone failed. If ${REPO} is private you need access to it: sign in with the GitHub CLI (gh auth login), ` +
        'configure a credential helper, or clone it manually and point this installer at the folder with --dir.'
    );
  }
  // robocopy is on every Windows box and handles the merge without a shell. 0-7 are success codes.
  const c = runCapture('robocopy', [stage, target, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP']);
  rmSync(stage, { recursive: true, force: true });
  if ((c.status ?? 8) > 7) fail('Copying the clone into the target folder failed.');
} else {
  console.log('\n  no git found - downloading the tarball');
  const url = `https://codeload.github.com/${REPO}/tar.gz/refs/heads/${ref}`;
  const tgz = join(tmpdir(), `psadt-skill-${Date.now()}.tar.gz`);
  try {
    const res = await fetch(url);
    if (res.status === 404) {
      // GitHub answers 404 - not 403 - for a private repository you cannot see. Without git there is no
      // way to authenticate here, so say what is actually wrong instead of "download failed".
      fail(
        `${REPO} is not publicly readable (HTTP 404), and without git this installer cannot authenticate. ` +
          'Either install git and sign in to GitHub, or clone the repository manually and re-run with ' +
          '--dir <folder>.'
      );
    }
    if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
    writeFileSync(tgz, Buffer.from(await res.arrayBuffer()));
  } catch (e) {
    fail(`Download failed: ${e.message}`);
  }
  // The archive's top-level directory is <repo>-<ref>/, so strip exactly one component.
  const r = run('tar', ['-xzf', tgz, '-C', target, '--strip-components=1']);
  rmSync(tgz, { force: true });
  if (r.status !== 0) fail('Extracting the tarball failed (tar.exe is expected in C:\\Windows\\System32).');
}

if (!existsSync(join(target, 'SKILL.md'))) {
  fail(`${target} has no SKILL.md - the download did not produce a skill folder.`);
}
console.log('  OK  skill files in place');

// --- 2. PowerShell ------------------------------------------------------------------------------
// pwsh first; powershell.exe as the fallback. -ExecutionPolicy Bypass on BOTH: 5.1 defaults to
// Restricted, and a GPO can pin pwsh to AllSigned - either way an unsigned script would not run.
const psExe = has('pwsh') ? 'pwsh' : 'powershell';
const psBase = ['-NoProfile', '-ExecutionPolicy', 'Bypass'];

// --- 3. record the commit (via the script that owns the config, not from here) -------------------
try {
  const res = await fetch(`https://api.github.com/repos/${REPO}/commits/${ref}`, {
    headers: { 'User-Agent': 'psadt-deploy-skill', Accept: 'application/vnd.github+json' },
  });
  if (res.ok) {
    const sha = (await res.json()).sha;
    if (sha) {
      const setCfg = join(target, 'scripts', 'Set-PsadtConfig.ps1');
      // -Command, not -File: -File passes every argument as a string and -Updates wants a hashtable.
      run(psExe, [...psBase, '-Command', `& '${setCfg}' -Updates @{'tooling.skillCommit'='${sha}'}`]);
      console.log(`  OK  recorded commit ${sha.slice(0, 7)}`);
    }
  } else if (res.status === 404) {
    // 404 on a repo you just cloned = the repo is private and this call is unauthenticated. Worth saying
    // once: the skill works, only the sha-based update check falls back to comparing versions.
    console.log(`  --  ${REPO} is not publicly readable, so the commit sha was not recorded.`);
    console.log('      The skill works; "update skill" compares CHANGELOG versions instead of shas.');
  } else {
    console.log(`  --  could not read the commit sha (HTTP ${res.status}) - not fatal`);
  }
} catch {
  // A missing commit sha only means the next update check compares versions instead of shas.
  console.log('  --  could not record the commit sha (offline?) - not fatal');
}

// --- 4. the setup doctor ------------------------------------------------------------------------
if (noSetup) {
  console.log('\n  skipped the setup doctor (--no-setup). Run it later:');
  console.log(`    ${psExe} -File "${join(target, 'scripts', 'Initialize-PsadtSkill.ps1')}" -Fix\n`);
  process.exit(0);
}

const doctor = join(target, 'scripts', 'Initialize-PsadtSkill.ps1');
const jsonPath = join(tmpdir(), `psadt-doctor-${Date.now()}.json`);
console.log('\n  running the setup doctor (-Fix)\n');
// -JsonPath rather than -Json: stdout is inherited so the user sees the doctor's own table live, and the
// machine-readable copy comes back through the file.
// -Command with Out-Null rather than -File: the doctor also RETURNS its result object, and with inherited
// stdout that object gets dumped underneath its own table. Out-Null drops the object; Write-Host output
// (the table) is unaffected.
const d = run(psExe, [...psBase, '-Command', `& '${doctor}' -Fix -JsonPath '${jsonPath}' | Out-Null`]);

let verdict = null;
try {
  if (existsSync(jsonPath)) verdict = JSON.parse(readFileSync(jsonPath, 'utf8'));
} catch {
  /* the doctor printed its table anyway */
}
rmSync(jsonPath, { force: true });

if (verdict) {
  console.log(`\n  setup: ${verdict.Overall}`);
  const missing = Array.isArray(verdict.Missing) ? verdict.Missing : [];
  if (missing.length) {
    console.log(`\n  ${missing.length} value(s) still need you: ${missing.join(', ')}`);
    console.log("  Open Claude Code in a package folder and say: \"psadt setup\"");
  } else if (verdict.Overall === 'GREEN') {
    console.log('  Ready. Open Claude Code and say what you want packaged.');
  }
} else if (d.status !== 0) {
  console.log('\n  The setup doctor did not complete. Run it manually:');
  console.log(`    ${psExe} -File "${doctor}" -Fix`);
}

console.log('');
