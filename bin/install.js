#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const os = require("os");

const CLAUDE_DIR = path.join(os.homedir(), ".claude");
const SETTINGS_FILE = path.join(CLAUDE_DIR, "settings.json");
const STATUSLINE_DEST = path.join(CLAUDE_DIR, "statusline.sh");
const STATUSLINE_SRC = path.resolve(__dirname, "statusline.sh");

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
// time. The probe used to be `which jq`, which execSync hands to cmd.exe on
// Windows — there is no `which` there, so all three looked missing and the
// install stopped before it started.
function checkDeps() {
  const { execFileSync } = require("child_process");
  const probe = DEPS.map((dep) => `command -v ${dep} >/dev/null || echo ${dep}`).join("\n");

  let found;
  try {
    found = execFileSync("bash", ["-c", probe], {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch {
    // No bash on PATH, so nothing here would run anyway — settings.json points
    // Claude Code at `bash "$HOME/.claude/statusline.sh"`.
    return ["bash"];
  }

  return found
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
}

function uninstall() {
  console.log();
  console.log(`  ${blue}Claude Line Uninstaller${reset}`);
  console.log(`  ${dim}───────────────────────${reset}`);
  console.log();

  const backup = STATUSLINE_DEST + ".bak";

  if (fs.existsSync(backup)) {
    fs.copyFileSync(backup, STATUSLINE_DEST);
    fs.unlinkSync(backup);
    success(`Restored previous statusline from ${dim}statusline.sh.bak${reset}`);
  } else if (fs.existsSync(STATUSLINE_DEST)) {
    fs.unlinkSync(STATUSLINE_DEST);
    success(`Removed ${dim}statusline.sh${reset}`);
  } else {
    warn("No statusline found — nothing to remove");
  }

  if (fs.existsSync(SETTINGS_FILE)) {
    try {
      const settings = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf-8"));
      if (settings.statusLine) {
        delete settings.statusLine;
        fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2) + "\n");
        success(`Removed statusLine from ${dim}settings.json${reset}`);
      } else {
        success("Settings already clean");
      }
    } catch {
      fail(`Could not parse ${SETTINGS_FILE} — fix it manually`);
      process.exit(1);
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

  const missing = checkDeps();
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

  if (!fs.existsSync(CLAUDE_DIR)) {
    fs.mkdirSync(CLAUDE_DIR, { recursive: true });
    success(`Created ${CLAUDE_DIR}`);
  }

  const backup = STATUSLINE_DEST + ".bak";
  if (fs.existsSync(STATUSLINE_DEST)) {
    if (fs.existsSync(backup)) {
      // A backup already there holds the user's own script from the first
      // install. Copying over it would replace it with ours, and --uninstall
      // would hand back the wrong file.
      log(`Keeping the existing ${dim}statusline.sh.bak${reset}`);
    } else {
      fs.copyFileSync(STATUSLINE_DEST, backup);
      warn(`Backed up existing statusline to ${dim}statusline.sh.bak${reset}`);
    }
  }

  fs.copyFileSync(STATUSLINE_SRC, STATUSLINE_DEST);
  fs.chmodSync(STATUSLINE_DEST, 0o755);
  success(`Installed statusline to ${dim}${STATUSLINE_DEST}${reset}`);

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
    command: 'bash "$HOME/.claude/statusline.sh"',
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

run();
