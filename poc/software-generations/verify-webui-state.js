#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const SOFTWARE_ROOT = '/software';
const EXPECTED_DIGEST = process.env.TEST_SOURCE_DIGEST;
const INHERITED_LOADER = process.env.EXPECTED_INHERITED_LD_LIBRARY_PATH;
const HASH = /^[0-9a-f]{64}$/;
const TARGET = /^generations\/([0-9a-f]{64})$/;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function listNames(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).map((entry) => entry.name).sort();
}

function inspectComponent(component) {
  const base = path.join(SOFTWARE_ROOT, component);
  assert(fs.statSync(base).isDirectory(), `${component} root is not a directory`);
  assert(listNames(path.join(base, 'staging')).length === 0, `${component} staging is not empty`);
  const generationRoot = path.join(base, 'generations');
  const generations = fs.readdirSync(generationRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort();
  assert(generations.length === 2, `${component} must contain exactly two generations`);
  for (const generation of generations) {
    assert(HASH.test(generation), `${component} generation name is invalid`);
    const generationPath = path.join(generationRoot, generation);
    assert(fs.statSync(path.join(generationPath, '.complete')).isFile(), `${component} generation is incomplete`);
    const metadata = readJson(path.join(generationPath, 'metadata.json'));
    assert(metadata.component === component, `${component} metadata component mismatch`);
    assert(metadata.software_root === SOFTWARE_ROOT, `${component} metadata software root mismatch`);
    assert(metadata.component_root === base, `${component} metadata component root mismatch`);
    assert(metadata.generation_path === generationPath, `${component} metadata generation path mismatch`);
    assert(metadata.generation_hash === generation, `${component} metadata generation hash mismatch`);
    assert(metadata.source_digest === EXPECTED_DIGEST, `${component} metadata source digest mismatch`);
  }
  const links = {};
  for (const name of ['current', 'previous']) {
    const link = path.join(base, name);
    assert(fs.lstatSync(link).isSymbolicLink(), `${component} ${name} is not a symlink`);
    const target = fs.readlinkSync(link);
    const match = TARGET.exec(target);
    assert(match, `${component} ${name} target is not a relative generation`);
    assert(generations.includes(match[1]), `${component} ${name} target is absent`);
    assert(fs.statSync(path.join(base, target, '.complete')).isFile(), `${component} ${name} target is incomplete`);
    links[name] = { target, hash: match[1], path: path.join(base, target) };
  }
  assert(links.current.target !== links.previous.target, `${component} current and previous are identical`);
  return links;
}

function checkResult(result, label) {
  assert(!result.error, `${label} failed to spawn: ${result.error && result.error.message}`);
  assert(result.signal === null, `${label} terminated by signal ${result.signal}`);
  assert(result.status === 0, `${label} exited ${result.status}: ${(result.stderr || '').trim()}`);
  return (result.stdout || '').trim();
}

assert(EXPECTED_DIGEST && /^sha256:[0-9a-f]{64}$/.test(EXPECTED_DIGEST), 'invalid expected Agent digest');
assert(typeof INHERITED_LOADER === 'string' && INHERITED_LOADER.length > 0, 'missing inherited WebUI loader path');
assert(JSON.stringify(listNames(SOFTWARE_ROOT)) === JSON.stringify(['node', 'python']), '/software must contain exactly node and python');
const pythonLinks = inspectComponent('python');
const nodeLinks = inspectComponent('node');
assert(pythonLinks.current.path.startsWith('/software/python/generations/'), 'Python metadata path escaped root');

const privateLibrary = `/software/node/generations/${nodeLinks.current.hash}/lib`;
const childEnvironment = { ...process.env, LD_LIBRARY_PATH: INHERITED_LOADER };
const options = { env: childEnvironment, shell: false, encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024 };
const effective = checkResult(spawnSync('/software/node/current/bin/node', ['-p', 'process.env.LD_LIBRARY_PATH'], options), 'node loader check');
assert(effective === `${privateLibrary}:${INHERITED_LOADER}`, 'effective Node loader path mismatch');
assert(effective.split(':').filter((entry) => entry === privateLibrary).length === 1, 'private Node loader path is duplicated');
checkResult(spawnSync('/software/node/current/bin/node', ['--version'], options), 'node');

fs.mkdirSync('/test-tmp/hostile', { recursive: true });
fs.writeFileSync('/test-tmp/hostile/node', '#!/bin/sh\nexit 99\n', { mode: 0o755, flag: 'w' });
const hostileEnvironment = { ...childEnvironment, PATH: `/test-tmp/hostile:/usr/bin:/bin` };
const hostileOptions = { env: hostileEnvironment, shell: false, encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024 };
checkResult(spawnSync('/software/node/current/bin/npm', ['--version'], hostileOptions), 'npm');
checkResult(spawnSync('/software/node/current/bin/npx', ['--version'], hostileOptions), 'npx');

console.log('webui-state-verifier=PASS');
console.log(`effective_ld_library_path=${effective}`);
console.log(`python_execution=SKIPPED_METADATA_ONLY current=${pythonLinks.current.hash}`);
