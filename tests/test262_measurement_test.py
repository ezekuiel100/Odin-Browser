"""Runner controls: expected failures must never become false passes."""
import argparse
import contextlib
import importlib.util
import io
import json
import gzip
from pathlib import Path
import sys
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
spec = importlib.util.spec_from_file_location("test262_runner", Path(__file__).resolve().parent.parent / "tools/test262-run.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
fetch_spec = importlib.util.spec_from_file_location("test262_fetch", Path(__file__).resolve().parent.parent / "tools/test262-fetch.py")
collector = importlib.util.module_from_spec(fetch_spec)
fetch_spec.loader.exec_module(collector)


class MetadataTests(unittest.TestCase):
    def test_strict_prefix_preserves_original_line_endings(self):
        with tempfile.TemporaryDirectory() as directory:
            suite = Path(directory)
            (suite/'test').mkdir()
            (suite/'harness').mkdir()
            for name in ('sta.js','assert.js'):
                (suite/'harness'/name).write_bytes(b'')
            source = '/*---\n---*/\n// CR\rvar x=1;\r\n'
            path = suite/'test/control.js'
            path.write_bytes(source.encode())
            args = argparse.Namespace(suite=suite, browser=Path('fake.exe'), timeout=1)
            def inspect(command, **kwargs):
                self.assertEqual(Path(command[-1]).read_bytes(), b'"use strict";\n'+source.encode())
                return SimpleNamespace(stdout='__262__ status=pass rec=0', stderr='', returncode=0)
            with patch.object(runner.subprocess, 'run', inspect):
                row = runner.execute((path, 'strict', {}, source), args)
            self.assertEqual(row['status'], 'PASS')

    def test_yaml_block_and_inline_lists(self):
        fm = runner.metadata('/*---\nflags:\n  - module\n  - async\nfeatures: [BigInt, "new.target"]\nnegative:\n  phase: runtime\n  type: TypeError\n---*/')
        self.assertEqual(fm['flags'], ['module', 'async'])
        self.assertEqual(fm['negative'], {'phase': 'runtime', 'type': 'TypeError'})

    def test_variants(self):
        for flags, expected in [([], ['normal', 'strict']), (['module'], ['module']),
                                (['raw'], ['normal']), (['noStrict'], ['normal']),
                                (['onlyStrict'], ['strict']), (['async'], ['normal', 'strict'])]:
            self.assertEqual(runner.variants(flags), expected)

    def test_invalid_metadata(self):
        for text in ('no frontmatter', '/*---\nflags: async\n---*/',
                     '/*---\nnegative:\n  phase: other\n  type: SyntaxError\n---*/'):
            with self.assertRaises(ValueError):
                runner.metadata(text)

    def test_verdict_rejects_wrong_phase_origin_and_recovery(self):
        negative = {'phase': 'parse', 'type': 'SyntaxError'}
        good = '__262__ status=throw name=SyntaxError phase=parse source=2 rec=0 msg=x'
        self.assertEqual(runner.verdict(good, 0, negative, 2)[0], 'PASS')
        for line in (good.replace('phase=parse', 'phase=runtime'), good.replace('source=2', 'source=0'),
                     good.replace('rec=0', 'rec=1'), good.replace('SyntaxError', 'TypeError')):
            self.assertEqual(runner.verdict(line, 0, negative, 2)[0], 'FAIL')
        for output, code in ((good, 1), (good+'\n'+good, 0), ('', 0)):
            self.assertEqual(runner.verdict(output, code, negative, 2)[0], 'ERROR')
        for line in ('__262__ status=incomplete reason=pending rec=0',
                     '__262__ status=invalid reason=multiple-done rec=0'):
            self.assertEqual(runner.verdict(line, 0, None, 2)[0], 'FAIL')


class CollectorTests(unittest.TestCase):
    def test_selection_keeps_unsupported_features_and_all_dependencies(self):
        with tempfile.TemporaryDirectory(prefix='test262-fetch-control-') as directory:
            root = Path(directory)
            revision = 'a' * 40
            cache = root/'cache'
            cache.mkdir()
            contents = {
                'harness/assert.js': b'assert', 'harness/sta.js': b'sta',
                'test/language/async.js': b'/*---\nflags: [async]\nfeatures: [not-yet-supported]\n---*/\r\n$DONE();',
                'test/language/module.js': b'/*---\nflags: [module]\n---*/\nimport "./dep_FIXTURE.js";',
                'test/language/dep_FIXTURE.js': b'export const n = 1;',
                'test/language/data_FIXTURE.json': b'{"n":1}',
                'test/built-ins/other.js': b'/*---\n---*/',
            }
            with tarfile.open(cache/(revision+'.tar.gz'), 'w:gz') as tar:
                for name, data in contents.items():
                    member = tarfile.TarInfo('test262-'+revision+'/'+name)
                    member.size = len(data)
                    tar.addfile(member, io.BytesIO(data))
            out = root/'out'
            argv = ['fetch', '--revision', revision, '--cache', str(cache), '--out', str(out),
                    '--per-dir', '0', '--only', 'language']
            with patch.object(sys, 'argv', argv), contextlib.redirect_stdout(io.StringIO()):
                collector.main()
            manifest = json.loads((out/'manifest.json').read_text())
            self.assertEqual(manifest['tests'], ['language/async.js','language/module.js'])
            self.assertEqual(manifest['selection']['featureExclusions'], [])
            for name, data in contents.items():
                if not name.startswith('test/built-ins/'):
                    self.assertEqual((out/name).read_bytes(), data)
            self.assertFalse((out/'test/built-ins/other.js').exists())


class HostTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.browser = Path(__file__).resolve().parent.parent / '_local/builds/test262.exe'
        if not cls.browser.exists():
            raise unittest.SkipTest('Build tools/js262 first')

    def test_execution_controls(self):
        with tempfile.TemporaryDirectory(prefix='test262-controls-') as directory:
            suite = Path(directory)
            (suite/'harness').mkdir()
            (suite/'test').mkdir()
            (suite/'harness/sta.js').write_text('function Test262Error(m){this.message=m;}')
            (suite/'harness/assert.js').write_text('function assert(v){if(!v)throw new Test262Error("assertion");}')
            args = argparse.Namespace(suite=suite, browser=self.browser, timeout=3)
            (suite/'test/dep_FIXTURE.js').write_text('export const value=42;')
            (suite/'test/broken_FIXTURE.js').write_text('return;')
            cases = [
                ('Promise.resolve().then(function(){$DONE();});', ['async'], None, 'PASS'),
                ('Promise.resolve(1);', ['async'], None, 'FAIL'),
                ('$DONE(); $DONE();', ['async'], None, 'FAIL'),
                ('$DONE(new TypeError("bad"));', ['async'], None, 'FAIL'),
                ('$DONE(); queueMicrotask(function(){throw new TypeError("uncaught");});', ['async'], None, 'FAIL'),
                ('$DONE(new TypeError("expected"));', ['async'], {'phase':'runtime','type':'TypeError'}, 'PASS'),
                ('throw new TypeError("expected");', [], {'phase':'runtime','type':'TypeError'}, 'PASS'),
                ('return;', [], {'phase':'parse','type':'SyntaxError'}, 'PASS'),
                ('throw new SyntaxError("runtime");', [], {'phase':'parse','type':'SyntaxError'}, 'FAIL'),
                ('assert(this===globalThis); assert($262.global===globalThis);', [], None, 'PASS'),
                ('assert($262.evalScript("1+2")===3);', [], None, 'PASS'),
                ('import {value} from "./dep_FIXTURE.js"; assert(value===42);', ['module'], None, 'PASS'),
                ('import {value} from "./dep_FIXTURE.js"; await Promise.resolve(); assert(value===42); $DONE();', ['module','async'], None, 'PASS'),
                ('export const broken = ;', ['module'], {'phase':'parse','type':'SyntaxError'}, 'PASS'),
                ('import "./broken_FIXTURE.js";', ['module'], {'phase':'parse','type':'SyntaxError'}, 'FAIL'),
                ('throw new TypeError("module"); export {};', ['module'], {'phase':'runtime','type':'TypeError'}, 'PASS'),
                ('if(typeof assert!=="undefined")throw new Error("raw harness leaked");', ['raw'], None, 'PASS'),
                ('$262.createRealm();', [], None, 'SKIP'),
                ('$262.agent.start("");', [], None, 'SKIP'),
                ('', ['CanBlockIsFalse'], None, 'SKIP'),
            ]
            for index, (source, flags, negative, expected) in enumerate(cases):
                path = suite/'test'/f'case{index}.js'
                path.write_text(source)
                fm = {'flags':flags}
                if negative:
                    fm['negative'] = negative
                variant = runner.variants(flags)[0]
                with self.subTest(index=index):
                    row = runner.execute((path, variant, fm, source), args)
                    self.assertEqual(row['status'], expected, row)

            # A matching error in an include must not satisfy the test's negative.
            (suite/'harness/bad.js').write_text('throw new TypeError("harness");')
            fm = {'includes':['bad.js'], 'negative':{'phase':'runtime','type':'TypeError'}}
            row = runner.execute((path, 'normal', fm, 'throw new TypeError("test");'), args)
            self.assertEqual(row['status'], 'FAIL', row)

    def test_report_and_named_comparison(self):
        with tempfile.TemporaryDirectory(prefix='test262-report-') as directory:
            suite = Path(directory)
            (suite/'test').mkdir()
            entry = suite/'test/control.js'
            entry.write_text('/*---\nflags: [raw]\n---*/\n1;')
            report = suite/'before.json'
            command = [sys.executable, str(runner.ROOT/'tools/test262-run.py'), '--suite', str(suite),
                       '--browser', str(self.browser), '--jobs', '1', '--report', str(report)]
            run = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            old = json.loads(report.read_text())
            self.assertEqual(old['counts'], {'PASS':1,'FAIL':0,'ERROR':0,'SKIP':0})
            self.assertTrue(old['browserSha256'])
            baseline = suite/'baseline.json.gz'
            baseline.write_bytes(gzip.compress(report.read_bytes(), mtime=0))
            entry.write_text('/*---\nflags: [raw]\n---*/\nthrow new TypeError("regression");')
            after = suite/'after.json'
            command[-1] = str(after)
            run = subprocess.run(command + ['--baseline', str(baseline)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 1, run.stderr)
            new = json.loads(after.read_text())
            self.assertEqual(new['changes'], [{'name':'control.js', 'variant':'normal', 'before':'PASS', 'after':'FAIL'}])


if __name__ == '__main__':
    unittest.main()
