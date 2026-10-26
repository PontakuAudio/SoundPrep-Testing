"""Check separate Lua/package and native/helper versions without rewriting sources."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
module_spec = importlib.util.spec_from_file_location(
    'generate_native_contract', ROOT / 'tools/generate_native_contract.py')
generator = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(generator)


class NativeContractVersions(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='am-native-contract-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'resources').mkdir()
        self.contract = json.loads((ROOT / 'resources/native-contract.json').read_text(encoding='utf-8'))
        self.patch = mock.patch.object(generator, 'ROOT', self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def write_versions(self, package='0.10.25', helper='0.10.21', cmake=None):
        self.contract['version'] = helper
        (self.root / 'resources/native-contract.json').write_text(
            json.dumps(self.contract), encoding='utf-8')
        (self.root / 'Audition Macro.lua').write_text(
            '' if package is None else f'-- @version {package}\n', encoding='utf-8')
        (self.root / 'CMakeLists.txt').write_text(
            f'project(AuditionMacro VERSION {helper if cmake is None else cmake} LANGUAGES C CXX)\n',
            encoding='utf-8')

    def test_lua_only_release_preserves_generated_helper_contracts(self):
        self.write_versions(package='0.10.21')
        before = generator.outputs()
        self.write_versions(package='0.10.25')
        self.assertEqual(generator.outputs(), before)
        self.assertIn('"version":"0.10.21"', before['native/contract.h'])

    def test_package_release_order_is_numeric(self):
        for package, helper in (('0.10.10', '0.10.9'), ('0.11.0', '0.10.99'), ('1.0.0', '0.99.99')):
            with self.subTest(package=package, helper=helper):
                self.write_versions(package=package, helper=helper)
                self.assertEqual(len(generator.outputs()), 2)

    def test_package_cannot_predate_bundled_helper(self):
        for package, helper in (('0.10.20', '0.10.21'), ('0.10.9', '0.10.10'), ('0.9.99', '0.10.0')):
            with self.subTest(package=package, helper=helper):
                self.write_versions(package=package, helper=helper)
                with self.assertRaisesRegex(SystemExit, 'package version is older'):
                    generator.outputs()

    def test_cmake_still_matches_helper_not_package(self):
        self.write_versions(cmake='0.10.25')
        with self.assertRaisesRegex(SystemExit, 'CMakeLists.txt version does not match'):
            generator.outputs()

    def test_malformed_or_missing_package_version_is_rejected(self):
        for value in (None, '', 'v0.10.25', '0.10', '0.10.25.1', '0.10.025', '0.10.25 extra', '0.10.25-beta1'):
            with self.subTest(version=value):
                self.write_versions(package=value)
                with self.assertRaisesRegex(SystemExit, r'Audition Macro.lua version must be'):
                    generator.outputs()

    def test_malformed_helper_and_cmake_versions_are_rejected(self):
        for source in ('helper', 'cmake'):
            for value in ('0.10', 'v0.10.21', '0.10.021'):
                with self.subTest(source=source, version=value):
                    self.write_versions(**{source: value})
                    with self.assertRaisesRegex(SystemExit, 'version must be'):
                        generator.outputs()


if __name__ == '__main__':
    unittest.main()
