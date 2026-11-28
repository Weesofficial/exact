// Unit tests for unitDepInfo across Cargo legacy deps/ and 1.100 build/<pkg>/<hash>/out layouts,
// including crates whose name starts with `lib`, Windows DLL/import-lib pairs, and MSVC `.lib` staticlibs.
import { test } from 'bun:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { unitDepInfo } from './cargo-dep-info.mjs';

function makeCase(fn) {
  const root = mkdtempSync(resolve(tmpdir(), 'exact-dep-info-'));
  try { fn(root); }
  finally { rmSync(root, { recursive: true, force: true }); }
}

test('unitDepInfo keeps crate names starting with lib intact for non-lib-prefixed outputs across all lookups', () => {
  for (const [ext, prefix] of [['.so', 'lib'], ['.dylib', 'lib'], ['.a', 'lib'], ['.rlib', 'lib'], ['.rmeta', 'lib'], ['.dll', ''], ['.wasm', ''], ['.lib', '']]) {
    const stem = prefix + 'libfoo';
    const modes = ext === '.rmeta' ? ['deps-hashed', 'out-direct'] : ['deps-unhashed', 'deps-hashed', 'out-unhashed', 'out-hashed', 'out-direct'];
    for (const mode of modes) {
      makeCase(root => {
        const profile = resolve(root, 'target/release');
        const src = resolve(root, 'src/lib.rs');
        const out = resolve(profile, 'build/libfoo/a11ce/out');
        const unitDir = mode.startsWith('deps') ? resolve(profile, 'deps') : out;
        const unitFile = mode.endsWith('hashed') || mode === 'out-direct' ? `${stem}-a11ce${ext}` : `${stem}${ext}`;
        const depFile = mode.endsWith('hashed') || mode === 'out-direct' ? 'libfoo-a11ce.d' : 'libfoo.d';
        mkdirSync(unitDir, { recursive: true });
        mkdirSync(profile, { recursive: true });
        const reported = mode === 'out-direct' ? resolve(out, unitFile) : ext === '.rmeta' ? resolve(unitDir, unitFile) : resolve(profile, `${stem}${ext}`);
        writeFileSync(reported, 'selected-bytes');
        writeFileSync(resolve(unitDir, unitFile), 'selected-bytes');
        const expected = resolve(unitDir, depFile);
        writeFileSync(expected, `${expected}: ${src}\n`);
        // Decoy `foo.d` tests that `.dll`/`.wasm`/`.lib` never strip `lib` from a crate named `libfoo`.
        if (!prefix) {
          const decoy = resolve(unitDir, depFile.replace(/^lib/, ''));
          writeFileSync(decoy, `${decoy}: ${src}\n`);
        }
        const metadata = {
          target_directory: resolve(root, 'target'),
          build_directory: resolve(root, 'target'),
          packages: [{ id: 'pkg-libfoo', name: 'libfoo' }],
        };
        const filenames = ext === '.dll' && mode !== 'out-direct'
          ? [resolve(profile, `${stem}.dll.lib`), reported]
          : [reported];
        if (ext === '.dll' && mode !== 'out-direct') writeFileSync(filenames[0], 'import-lib');
        const message = {
          package_id: 'pkg-libfoo',
          filenames,
          executable: null,
          target: { name: 'libfoo', src_path: src, kind: ['cdylib'] },
        };
        assert.equal(unitDepInfo(message, root, metadata), expected, `${ext} ${mode}`);
      });
    }
  }
});

test('unitDepInfo ignores Windows .dll.lib import libraries when resolving a copied DLL', () => {
  makeCase(root => {
    const profile = resolve(root, 'target/x86_64-pc-windows-msvc/release');
    const out = resolve(profile, 'build/game-gpu/a11ce/out');
    const src = resolve(root, 'src/lib.rs');
    mkdirSync(out, { recursive: true });
    const imp = resolve(profile, 'game_gpu.dll.lib');
    const dll = resolve(profile, 'game_gpu.dll');
    writeFileSync(imp, 'import-lib');
    writeFileSync(dll, 'dll-bytes');
    writeFileSync(resolve(out, 'game_gpu-a11ce.dll'), 'dll-bytes');
    const expected = resolve(out, 'game_gpu-a11ce.d');
    writeFileSync(expected, `${expected}: ${src}\n`);
    const metadata = {
      target_directory: resolve(root, 'target'),
      build_directory: resolve(root, 'target'),
      packages: [{ id: 'gpu', name: 'game-gpu' }],
    };
    const message = {
      package_id: 'gpu',
      filenames: [imp, dll],
      executable: null,
      target: { name: 'game_gpu', src_path: src, kind: ['cdylib'] },
    };
    assert.equal(unitDepInfo(message, root, metadata), expected);
    // Ensure dirname import isn't unused if extended.
    assert.equal(dirname(expected), out);
  });
});
