#!/usr/bin/env node
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execSync } = require('child_process');

const root = path.resolve(__dirname, '..');
let failures = 0;

const colors = process.stdout.isTTY ? {
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  red: '\x1b[31m',
  reset: '\x1b[0m',
} : {
  green: '',
  yellow: '',
  red: '',
  reset: '',
};

function rel(file) {
  return path.relative(root, file) || '.';
}

function ok(message) {
  console.log(`${colors.green}[ok]${colors.reset} ${message}`);
}

function warn(message) {
  console.log(`${colors.yellow}[warn]${colors.reset} ${message}`);
}

function fail(message) {
  failures += 1;
  console.log(`${colors.red}[fail]${colors.reset} ${message}`);
}

function exists(relativePath) {
  const fullPath = path.join(root, relativePath);
  if (fs.existsSync(fullPath)) ok(`${relativePath} exists`);
  else fail(`${relativePath} is missing`);
}

function command(commandLine) {
  try {
    return execSync(commandLine, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch (_) {
    return '';
  }
}

function checkNodeVersion() {
  const major = Number(process.versions.node.split('.')[0]);
  if (major >= 18) ok(`Node ${process.version}`);
  else fail(`Node 18+ required, found ${process.version}`);
}

function checkPackageJson() {
  const packagePath = path.join(root, 'package.json');
  try {
    const pkg = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
    for (const dep of ['express', 'ws']) {
      if (pkg.dependencies && pkg.dependencies[dep]) ok(`dependency declared: ${dep}`);
      else fail(`dependency missing in package.json: ${dep}`);
    }
  } catch (error) {
    fail(`package.json is not valid JSON: ${error.message}`);
  }
}

function checkServices() {
  if (process.platform === 'win32') {
    warn('systemd checks skipped on Windows');
    return;
  }

  const systemctl = command('command -v systemctl');
  if (!systemctl) {
    warn('systemctl not available on this machine');
    return;
  }

  for (const service of ['fluid-server', 'fluid-display']) {
    const state = command(`systemctl is-active ${service}`);
    if (state === 'active') ok(`${service} is active`);
    else warn(`${service} is ${state || 'not installed/active'}`);
  }
}

function checkInstallConfig() {
  const localEnv = path.join(root, '.env');
  if (fs.existsSync(localEnv)) ok(`${rel(localEnv)} found for local development`);
  else warn('.env not found; local development will use built-in defaults');

  const installedEnv = '/etc/fluid/fluid.env';
  if (process.platform !== 'win32' && fs.existsSync(installedEnv)) ok(`${installedEnv} found`);
  else if (process.platform !== 'win32') warn(`${installedEnv} not found; normal before installing on the Pi`);
}

console.log('\nFluid doctor');
console.log(`Repo: ${root}`);
console.log(`Platform: ${os.platform()} ${os.release()}\n`);

for (const file of [
  'server.js',
  'package.json',
  'install.sh',
  'start-kiosk.sh',
  'public/index.html',
  'public/client.html',
  'public/admin.html',
  'public/display.html',
  'systemd/fluid-server.service',
  'systemd/fluid-display.service',
]) {
  exists(file);
}

console.log('\nRuntime');
checkNodeVersion();
const npmCommand = process.platform === 'win32' ? 'npm.cmd' : 'npm';
const npmFromUserAgent = (process.env.npm_config_user_agent || '').match(/npm\/([^\s]+)/)?.[1];
const npmVersion = npmFromUserAgent || command(`${npmCommand} --version`);
if (npmVersion) ok(`npm ${npmVersion}`);
else warn('npm version could not be detected from this shell');

if (fs.existsSync(path.join(root, 'node_modules'))) ok('node_modules installed');
else warn('node_modules missing; run npm install');

console.log('\nPackage');
checkPackageJson();

console.log('\nConfiguration');
checkInstallConfig();

console.log('\nServices');
checkServices();

console.log('');
if (failures > 0) {
  fail(`${failures} check(s) failed`);
  process.exit(1);
}

ok('No blocking issues found');
