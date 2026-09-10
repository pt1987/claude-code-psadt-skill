#!/usr/bin/env node
/**
 * psadt-deploy-skill - installer for the psadt-deploy Claude Code skill.
 *
 *   npx psadt-deploy-skill                 install/update the newest release in ~/.claude/skills/psadt-deploy
 *   npx psadt-deploy-skill --project       install into ./.claude/skills/psadt-deploy instead
 *   npx psadt-deploy-skill --dir <path>    install into an explicit folder
 *   npx psadt-deploy-skill --ref v0.26.7   pin an exact release
 *   npx psadt-deploy-skill --ref main      the development branch, explicitly
 *   npx psadt-deploy-skill --no-setup      skip the setup doctor
 *
 * Design notes that matter:
 *
 * - Zero dependencies. Node 18 has global fetch, Windows ships bsdtar as tar.exe, and an installer that
 *   pulls in a dependency tree is an installer that can break for reasons unrelated to the skill.
 * - The default is the newest RELEASE TAG, not main. This skill registers an Entra app with admin
 *   consent and writes to an Intune tenant; installing whatever happened to land on main an hour ago is
 *   not a defensible default for that. main is still one flag away.
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
const explicitRef = flagValue('--ref');
const noSetup = argv.includes('--no-setup');
const explicitDir = flagValue('--dir');
const projectScope = argv.includes('--project');

if (wantHelp) {
  console.log(`psadt-deploy-skill - install the psadt-deploy Claude Code skill

  npx psadt-deploy-skill [--dir <path>] [--project] [--ref <tag|branch>] [--no-setup]

  --dir <path>   install into this folder
  --project      install into ./.claude/skills/${SKILL_FOLDER} (default is the user's ~/.claude/skills)
  --ref <ref>    tag or branch to install. Default: the newest release tag.
                 --ref v0.26.7  pin an exact release (recommended for managed environments)
                 --ref main     the development branch
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
// Thrown by fail() to unwind out of main(). Nothing else throws it and nothing else catches it.
class InstallFailure extends Error {}
function fail(msg) {
  console.error(`\n  ERROR  ${msg}\n`);
  // Deliberately NOT process.exit(). Once Node's fetch has opened a pooled socket, an explicit exit
  // aborts the process with "Assertion failed: !(handle->flags & UV_HANDLE_CLOSING)" and exit code
  // 127 instead of 1 - so a mistyped --ref prints a correct error message and then looks like an
  // installer crash, and any wrapper reading the exit code gets the wrong number. Setting exitCode
  // and unwinding lets the event loop drain, which exits 1 cleanly.
  process.exitCode = 1;
  throw new InstallFailure(msg);
}

async function main() {
  if (process.platform !== 'win32') {
    fail('This skill builds Windows Intune packages and needs Windows (PowerShell, IntuneWinAppUtil, PSADT).');
  }

  // --- which ref ----------------------------------------------------------------------------------
  // Without --ref this installs the newest RELEASE TAG. The tag list is the only source: this repository
  // publishes tags rather than GitHub Releases, so /releases/latest answers 404 here.
  async function newestReleaseTag() {
    try {
      const res = await fetch(`https://api.github.com/repos/${REPO}/tags?per_page=100`, {
        headers: { 'User-Agent': 'psadt-deploy-skill', Accept: 'application/vnd.github+json' },
      });
      if (!res.ok) return null;
      const semver = /^v(\d+)\.(\d+)\.(\d+)$/;
      const tags = (await res.json())
        .map((t) => [t.name, semver.exec(t.name)])
        .filter(([, m]) => m)
        // The API orders tags by commit date, which is not version order once anything is tagged out of
        // sequence. Sort numerically per component - a string sort would put v0.9.0 above v0.26.7.
        .sort((a, b) => Number(b[1][1]) - Number(a[1][1]) || Number(b[1][2]) - Number(a[1][2]) || Number(b[1][3]) - Number(a[1][3]));
      return tags.length ? tags[0][0] : null;
    } catch {
      return null;
    }
  }

  let ref = explicitRef;
  let refNote = '';
  if (!ref) {
    ref = await newestReleaseTag();
    refNote = '  (newest release)';
    if (!ref) {
      // Offline, rate-limited, or a repository this machine cannot read. Falling back keeps the
      // installer working; saying so out loud keeps the user from believing they got a pinned release.
      ref = 'main';
      refNote = '  (FALLBACK: could not read the tag list, installing the development branch)';
    }
  }

  console.log(`\npsadt-deploy-skill\n  target : ${target}\n  ref    : ${ref}${refNote}`);

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
      fail(
        `git pull --ff-only origin ${ref} failed. Three usual causes: local changes in the skill folder ` +
          '(commit or discard them); the clone is already AHEAD of the newest release, which is normal on a ' +
          'development clone (re-run with --ref main); or the ref does not exist. Failing that, install into ' +
          'a fresh folder with --dir.'
      );
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
    // The bare-ref form, NOT refs/heads/<ref>: refs/heads only resolves BRANCHES, so every tag 404'd on
    // this route while working fine on the two git routes - which is exactly the route a managed machine
    // without git ends up on, and exactly the ref a managed machine should be pinning.
    const url = `https://codeload.github.com/${REPO}/tar.gz/${ref}`;
    const tgz = join(tmpdir(), `psadt-skill-${Date.now()}.tar.gz`);
    try {
      const res = await fetch(url);
      if (res.status === 404) {
        // GitHub answers 404 - not 403 - both for a private repository you cannot see and for a ref that
        // does not exist. Without git there is no way to authenticate here, so name both possibilities
        // instead of "download failed".
        fail(
          `Could not download ${REPO} at ref "${ref}" (HTTP 404). Either that tag/branch does not exist, ` +
            'or the repository is not publicly readable and this installer cannot authenticate without git. ' +
            'Check the ref, or install git and sign in to GitHub, or clone the repository manually and ' +
            're-run with --dir <folder>.'
        );
      }
      if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
      writeFileSync(tgz, Buffer.from(await res.arrayBuffer()));
    } catch (e) {
      // The 404 branch above already reported precisely what is wrong and threw; letting it fall in
      // here would re-wrap that message as "Download failed: <the whole explanation>".
      if (e instanceof InstallFailure) throw e;
      fail(`Download failed: ${e.message}`);
    }
    // The archive's top-level directory is <repo>-<ref-without-any-leading-v>/, so strip one component
    // rather than trying to predict the name.
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
        // The ref is recorded next to the sha because Update-PsadtSkill.ps1 cannot otherwise tell a
        // release-pinned installation from one tracking main, and would report a pinned machine as
        // permanently "behind" every time main moved.
        // -Command, not -File: -File passes every argument as a string and -Updates wants a hashtable.
        run(psExe, [...psBase, '-Command', `& '${setCfg}' -Updates @{'tooling.skillCommit'='${sha}'; 'tooling.skillRef'='${ref}'}`]);
        console.log(`  OK  recorded commit ${sha.slice(0, 7)} at ref ${ref}`);
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
    return;
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
}

// process.exit(0) has the same libuv problem as process.exit(1) once a fetch has run, so the
// happy paths return out of main() instead of exiting and the process ends by draining the loop.
try {
  await main();
} catch (e) {
  if (!(e instanceof InstallFailure)) throw e;
}
