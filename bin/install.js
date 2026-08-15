#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const os = require("os");
const crypto = require("crypto");
const { execFileSync } = require("child_process");

// Claude Code reads its own configuration from CLAUDE_CONFIG_DIR when that is
// set, and from ~/.claude otherwise. Following it is what makes a second
// profile installable: the settings.json in there is the only one that session
// reads, and the script has to land beside it.
const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR
  ? path.resolve(process.env.CLAUDE_CONFIG_DIR)
  : path.join(os.homedir(), ".claude");
const SETTINGS_FILE = path.join(CLAUDE_DIR, "settings.json");
const STATUSLINE_DEST = path.join(CLAUDE_DIR, "statusline.sh");
const STATUSLINE_SRC = path.resolve(__dirname, "statusline.sh");

// A POSIX shell resolves the profile itself at render time, so one settings.json
// keeps working across machines whose $HOME differs and across profiles.
const POSIX_COMMAND = 'bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline.sh"';
// What every release up to 2.0.0 wrote. Still recognised, so an upgrade
// replaces it and an uninstall knows the setting is ours to remove.
const LEGACY_COMMANDS = ['bash "$HOME/.claude/statusline.sh"'];

// The installed script says which release it came from, so a stale copy is
// recognisable — by the user reading it, by us when deciding whether the copy
// is worth redoing, and by anyone reporting a bug against a six-month-old file.
// npm always ships package.json, whatever "files" says.
const VERSION = require("../package.json").version;
const VERSION_LINE = /^# statusline-version: *(.*)$/m;

// Exact statusline payloads published before the ownership marker existed.
// 1.0.0–1.0.6 produced five distinct files; accepting only their hashes keeps
// old installs uninstallable without claiming an arbitrary user script.
const LEGACY_SCRIPT_HASHES = new Set([
  "7eb1f63b94cda1c9a117a66b9bb2c15bcd986c87b7a18959f814597f8945cc1e",
  "99bd77b12f42ec777b6872b121670cb44d6ec70f24313898719db890f5189027",
  "43da70c2ce7dda732ba4d68b6d96e2cbdcde0f86d9b02d0cd806430d63b5db8a",
  "3c62b304e51259ed3bb7d84d582be061b4b52820e0fcbfb21c5cf89c661b820a",
  "f1e6e4ded63bd4fb645a26390c73ef6c06a47a26baf0adb81926ec2949d599be",
]);

const blue = "\x1b[38;2;0;153;255m";
const green = "\x1b[38;2;0;175;80m";
const red = "\x1b[38;2;255;85;85m";
const yellow = "\x1b[38;2;230;200;0m";
const dim = "\x1b[2m";
const reset = "\x1b[0m";

function log(msg) {
  console.log(`  ${msg}`);
}

function success(msg) {
  console.log(`  ${green}✓${reset} ${msg}`);
}

function warn(msg) {
  console.log(`  ${yellow}!${reset} ${msg}`);
}

function fail(msg) {
  console.error(`  ${red}✗${reset} ${msg}`);
}

const DEPS = ["jq", "curl", "git"];

// curl and git come with the OS or with Git for Windows; jq is the one people
// have to go and get, so the failure message says how.
const JQ_INSTALL =
  {
    darwin: "brew install jq",
    win32: "winget install jqlang.jq",
  }[process.platform] || "sudo apt install jq, or whatever your distro uses";

// Ask bash what it can see, since bash is what runs the statusline at render
// time — the same bash the command will name. The probe used to be `which jq`,
// which execSync hands to cmd.exe on Windows — there is no `which` there, so
// all three looked missing and the install stopped before it started.
function checkDeps(bashPath) {
  const probe = DEPS.map((dep) => `command -v ${dep} >/dev/null || echo ${dep}`).join("\n");

  let found;
  try {
    found = execFileSync(bashPath || "bash", ["-c", probe], {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch {
    // No bash to be had, so nothing here would run anyway — settings.json
    // points Claude Code at a bash invocation.
    return ["bash"];
  }

  return found
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
}

// Git Bash takes C:/Users/… as readily as the backslash spelling, and a
// settings.json without escaped separators is the one a user can read.
function toBashPath(file) {
  return file.replace(/\\/g, "/");
}

// Claude Code runs a status line through the platform shell, which on Windows
// is `cmd.exe /d /s /c`. That expands neither `$HOME` nor
// `${CLAUDE_CONFIG_DIR:-…}`, and has no `bash` on PATH — Git for Windows adds
// only its cmd directory there, and the bash.exe Windows itself ships is the
// WSL launcher. So Windows gets both paths resolved here, at install time.
function statusLineCommand(platform, claudeDir, bashPath) {
  if (platform !== "win32") return POSIX_COMMAND;
  return `"${bashPath}" "${toBashPath(path.join(claudeDir, "statusline.sh"))}"`;
}

// `where` prints every match on PATH, one per line, and exits non-zero when
// there are none.
function whereAll(name) {
  try {
    return execFileSync("where", [name], {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "ignore"],
    })
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
  } catch {
    return [];
  }
}

// Git for Windows keeps bash.exe in <root>\bin, and that is the copy to use:
// it sets up the MSYS environment, while <root>\usr\bin\bash.exe starts
// without /usr/bin on PATH, so jq, curl and the coreutils this script calls all
// come back "not found".
function bashCandidates() {
  const found = [];
  const add = (candidate) => {
    if (candidate && !found.includes(candidate)) found.push(candidate);
  };

  add(process.env.CLAUDE_LINE_BASH);

  // git is on PATH far more often than bash is, and it lives in the same
  // install: both cmd\git.exe and mingw64\bin\git.exe sit under <root>.
  for (const gitPath of whereAll("git")) {
    let dir = path.dirname(gitPath);
    for (let up = 0; up < 3; up++) {
      add(path.join(dir, "bin", "bash.exe"));
      const parent = path.dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
  }

  for (const root of [
    process.env.ProgramW6432,
    process.env.ProgramFiles,
    process.env["ProgramFiles(x86)"],
  ]) {
    if (root) add(path.join(root, "Git", "bin", "bash.exe"));
  }
  if (process.env.LOCALAPPDATA) {
    add(path.join(process.env.LOCALAPPDATA, "Programs", "Git", "bin", "bash.exe"));
  }

  // Then whatever else is on PATH, minus the WSL launcher in System32: that
  // one runs inside a Linux distribution, or just prints an install prompt
  // when there is none.
  const wsl = path.join(process.env.SystemRoot || "C:\\Windows", "System32").toLowerCase();
  for (const candidate of whereAll("bash")) {
    if (!candidate.toLowerCase().startsWith(wsl)) add(candidate);
  }

  return found;
}

function findBash() {
  for (const candidate of bashCandidates()) {
    if (!fs.existsSync(candidate)) continue;
    try {
      execFileSync(candidate, ["-c", "exit 0"], { stdio: "ignore" });
      return candidate;
    } catch {
      // There but not runnable: a stale PATH entry, or a bash whose DLLs are
      // not where it expects them.
    }
  }
  return null;
}

// The repo copy carries `dev`; the installed one carries the release it came
// from. A source without the marker installs unstamped rather than blowing up
// in the user's face — test/install.sh is what keeps it there.
function stampedSource() {
  const source = fs.readFileSync(STATUSLINE_SRC, "utf-8");
  return source.replace(VERSION_LINE, `# statusline-version: ${VERSION}`);
}

function versionOf(script) {
  const found = script.match(VERSION_LINE);
  return found && found[1] !== "dev" ? found[1] : null;
}

function isManagedScript(script) {
  if (versionOf(script) !== null) return true;
  const hash = crypto.createHash("sha256").update(script, "utf8").digest("hex");
  return LEGACY_SCRIPT_HASHES.has(hash);
}

function fileState(file) {
  try {
    const stat = fs.lstatSync(file);
    if (!stat.isFile()) return { exists: true, safe: false, content: null };
    return { exists: true, safe: true, content: fs.readFileSync(file, "utf8") };
  } catch (error) {
    if (error.code === "ENOENT") return { exists: false, safe: true, content: null };
    throw error;
  }
}

function isManagedSetting(statusLine) {
  if (!statusLine || statusLine.type !== "command" || typeof statusLine.command !== "string") {
    return false;
  }
  if (statusLine.command === POSIX_COMMAND) return true;
  if (LEGACY_COMMANDS.includes(statusLine.command)) return true;
  // A Windows install names the bash it found, and that path moves between Git
  // releases, so what identifies the setting there is the script it runs.
  return (
    process.platform === "win32" &&
    /bash(\.exe)?"?\s/i.test(statusLine.command) &&
    statusLine.command.endsWith(`"${toBashPath(STATUSLINE_DEST)}"`)
  );
}

function uninstall() {
  console.log();
  console.log(`  ${blue}Claude Line Uninstaller${reset}`);
  console.log(`  ${dim}───────────────────────${reset}`);
  console.log();

  let settings = null;
  if (fs.existsSync(SETTINGS_FILE)) {
    try {
      settings = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf-8"));
    } catch {
      fail(`Could not parse ${SETTINGS_FILE} — fix it manually`);
      process.exit(1);
    }
  }

  const backup = STATUSLINE_DEST + ".bak";
  let installed;
  let saved;
  try {
    installed = fileState(STATUSLINE_DEST);
    saved = fileState(backup);
  } catch {
    fail("Could not inspect statusline files — nothing was changed");
    process.exit(1);
  }

  const managedScript = installed.safe && installed.exists && isManagedScript(installed.content);
  const managedBackup = saved.safe && saved.exists && isManagedScript(saved.content);
  const managedSetting = isManagedSetting(settings && settings.statusLine);
  let managedRemoved = false;

  if (managedScript) {
    if (saved.exists && !saved.safe) {
      fail(`Refusing unsafe ${dim}statusline.sh.bak${reset} — nothing was changed`);
      process.exit(1);
    }
    if (managedBackup) {
      fs.unlinkSync(STATUSLINE_DEST);
      fs.unlinkSync(backup);
      success(`Removed ${dim}statusline.sh${reset} and stale package backup`);
    } else if (saved.exists) {
      fs.copyFileSync(backup, STATUSLINE_DEST);
      fs.unlinkSync(backup);
      success(`Restored previous statusline from ${dim}statusline.sh.bak${reset}`);
    } else {
      fs.unlinkSync(STATUSLINE_DEST);
      success(`Removed ${dim}statusline.sh${reset}`);
    }
    managedRemoved = true;
  } else if (!installed.exists && managedSetting) {
    if (saved.exists && !saved.safe) {
      fail(`Refusing unsafe ${dim}statusline.sh.bak${reset} — nothing was changed`);
      process.exit(1);
    }
    if (managedBackup) {
      fs.unlinkSync(backup);
      warn("No statusline found — removed stale package backup");
    } else if (saved.exists) {
      fs.copyFileSync(backup, STATUSLINE_DEST);
      fs.unlinkSync(backup);
      success(`Restored previous statusline from ${dim}statusline.sh.bak${reset}`);
    } else {
      warn("No statusline found — nothing to remove");
    }
    managedRemoved = true;
  } else if (installed.exists) {
    warn("Existing statusline is not managed by this package — left unchanged");
  } else {
    warn("No statusline found — nothing to remove");
  }

  if (settings) {
    if (managedSetting && managedRemoved) {
      delete settings.statusLine;
      fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2) + "\n");
      success(`Removed statusLine from ${dim}settings.json${reset}`);
    } else if (settings.statusLine) {
      warn("statusLine setting was left unchanged");
    } else {
      success("Settings already clean");
    }
  }

  console.log();
  log(`${green}Done!${reset} Restart Claude Code to apply changes.`);
  console.log();
}

function run() {
  if (process.argv.includes("--uninstall")) {
    uninstall();
    return;
  }

  console.log();
  console.log(`  ${blue}Claude Line Installer${reset}`);
  console.log(`  ${dim}─────────────────────${reset}`);
  console.log();

  // Nothing on Windows can rely on `bash` being on PATH at render time, so the
  // install finds one now and writes its full path into the command.
  let bashPath = null;
  if (process.platform === "win32") {
    bashPath = findBash();
    if (!bashPath) {
      fail("Could not find a bash to run the statusline");
      log(`  ${dim}Install Git for Windows, or set CLAUDE_LINE_BASH to a bash.exe${reset}`);
      process.exit(1);
    }
  }

  const missing = checkDeps(bashPath);
  if (missing.length > 0) {
    fail(`Missing required dependencies: ${missing.join(", ")}`);
    log(`  Install them and try again.`);
    if (missing.includes("bash")) {
      log(`  ${dim}Claude Code runs the statusline through bash${reset}`);
    }
    if (missing.includes("jq")) {
      log(`  ${dim}${JQ_INSTALL}${reset}`);
    }
    process.exit(1);
  }
  success(`Dependencies found (${DEPS.join(", ")})`);
  if (bashPath) {
    log(`  ${dim}${bashPath}${reset}`);
  }

  if (!fs.existsSync(CLAUDE_DIR)) {
    fs.mkdirSync(CLAUDE_DIR, { recursive: true });
    success(`Created ${CLAUDE_DIR}`);
  }

  const backup = STATUSLINE_DEST + ".bak";
  const wanted = stampedSource();
  const installed = fs.existsSync(STATUSLINE_DEST)
    ? fs.readFileSync(STATUSLINE_DEST, "utf-8")
    : null;

  if (installed === wanted) {
    success(`Statusline already at ${VERSION}`);
  } else {
    // Only a script we do not recognise can be the user's own, and only that is
    // worth backing up. This includes the exact published payloads from before
    // the version marker existed.
    if (installed !== null && !isManagedScript(installed)) {
      if (fs.existsSync(backup)) {
        log(`Keeping the existing ${dim}statusline.sh.bak${reset}`);
      } else {
        fs.copyFileSync(STATUSLINE_DEST, backup);
        warn(`Backed up existing statusline to ${dim}statusline.sh.bak${reset}`);
      }
    }

    fs.writeFileSync(STATUSLINE_DEST, wanted);
    fs.chmodSync(STATUSLINE_DEST, 0o755);
    const from = versionOf(installed || "");
    success(
      from
        ? `Updated statusline ${from} → ${VERSION} in ${dim}${STATUSLINE_DEST}${reset}`
        : `Installed statusline ${VERSION} to ${dim}${STATUSLINE_DEST}${reset}`,
    );
  }

  let settings = {};
  if (fs.existsSync(SETTINGS_FILE)) {
    try {
      settings = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf-8"));
    } catch {
      fail(`Could not parse ${SETTINGS_FILE} — fix it manually`);
      process.exit(1);
    }
  }

  const statusLineConfig = {
    type: "command",
    command: statusLineCommand(process.platform, CLAUDE_DIR, bashPath),
  };

  if (
    settings.statusLine &&
    settings.statusLine.type === "command" &&
    settings.statusLine.command === statusLineConfig.command
  ) {
    success("Settings already configured");
  } else {
    settings.statusLine = statusLineConfig;
    fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2) + "\n");
    success(`Updated ${dim}settings.json${reset} with statusLine config`);
  }

  console.log();
  log(`${green}Done!${reset} Restart Claude Code to see your new status line.`);
  console.log();
}

// The Windows command is assembled from paths that only exist on Windows, so
// the suite calls the builder directly rather than installing there.
module.exports = { statusLineCommand, POSIX_COMMAND };

if (require.main === module) run();
