"""Launchpad string catalog checks: stale, missing, untranslated, placeholders, languages."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('check_launchpad_strings', ROOT / 'scripts/check_launchpad_strings.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def entry(zh, en=None, state='translated', extra=None):
    localizations = {'zh-Hans': {'stringUnit': {'state': state, 'value': zh}}}
    if en is not None:
        localizations['en'] = {'stringUnit': {'state': 'translated', 'value': en}}
    localizations.update(extra or {})
    return {'localizations': localizations}


class LaunchpadStringsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.sources = self.base / 'Sources'
        self.sources.mkdir()
        (self.sources / 'View.swift').write_text(
            'Text("Machines")\n'
            'TableColumn("Name", value: \\.name)\n'
            'Text(verbatim: "not a key")\n'
            'let s = String(localized: "Bridged to \\(name.uppercased(with: Locale(identifier: "en")))")\n'
            '.help(Text(verbatim: path))\n'
        )
        self.catalog = self.base / 'Localizable.xcstrings'
        self.infoplist_catalog = self.base / 'InfoPlist.xcstrings'
        self.info_plist = self.base / 'Info.plist'
        self.info_plist.write_bytes(plistlib.dumps({'CFBundleName': 'x', 'CFBundleIdentifier': 'y'}))
        self.write(self.infoplist_catalog, {'CFBundleName': entry('x', 'x')})
        self.strings = {
            'Machines': entry('虚拟机', 'Machines'),
            'Name': entry('名称'),
            'Bridged to %@': entry('桥接到 %@', 'Bridged to %@'),
        }

    def write(self, path, strings, source_language='en'):
        path.write_text(json.dumps({'sourceLanguage': source_language, 'strings': strings, 'version': '1.0'}))

    def run_check(self):
        self.write(self.catalog, self.strings)
        issues, summary = module.run([self.sources], self.catalog, self.infoplist_catalog, self.info_plist)
        return issues, summary

    def test_consistent_catalog_passes(self):
        issues, summary = self.run_check()
        self.assertEqual(issues, [])
        self.assertIn('3 keys, 3 source literals', summary)

    def test_interpolation_with_nested_quotes_is_one_placeholder(self):
        found = module.extract_literals([self.sources])
        self.assertIn('Bridged to %@', found)
        self.assertNotIn('not a key', found)

    def test_labeled_content_title_is_a_key(self):
        (self.sources / 'Inspector.swift').write_text('LabeledContent("Started") { Text(verbatim: time) }\n')
        found = module.extract_literals([self.sources])
        self.assertIn('Started', found)

    def test_form_control_titles_are_keys(self):
        (self.sources / 'Settings.swift').write_text(
            'Stepper("CPU: \\(cpu) cores", value: $cpu)\n'
            'Picker("Mode", selection: $network) { }\n'
            'TextField("Interface", text: $name, prompt: Text("First available"))\n')
        found = module.extract_literals([self.sources])
        for key in ('CPU: %@ cores', 'Mode', 'Interface', 'First available'):
            self.assertIn(key, found)

    def test_stale_key(self):
        self.strings['Unused'] = entry('未使用', 'Unused')
        issues, _ = self.run_check()
        self.assertEqual(issues, ["Localizable: stale: 'Unused'"])

    def test_missing_key(self):
        del self.strings['Name']
        issues, _ = self.run_check()
        self.assertEqual(len(issues), 1)
        self.assertIn("missing: 'Name'", issues[0])
        self.assertIn('View.swift:2', issues[0])

    def test_untranslated_key(self):
        self.strings['Name'] = {'localizations': {}}
        issues, _ = self.run_check()
        self.assertEqual(issues, ["Localizable: untranslated (zh-Hans): 'Name'"])

    def test_new_state_is_not_a_translation(self):
        self.strings['Name'] = entry('名称', state='new')
        issues, _ = self.run_check()
        self.assertEqual(issues, ["Localizable: untranslated (zh-Hans): 'Name'"])

    def test_needs_review_is_accepted_and_counted(self):
        self.strings['Name'] = entry('名称', state='needs_review')
        issues, summary = self.run_check()
        self.assertEqual(issues, [])
        self.assertIn('needs_review: 1', summary)

    def test_placeholder_mismatch(self):
        self.strings['Bridged to %@'] = entry('桥接到 %lld', 'Bridged to %@')
        issues, _ = self.run_check()
        self.assertEqual(issues, ["Localizable: placeholder mismatch (zh-Hans): 'Bridged to %@' -> '桥接到 %lld'"])

    def test_unsupported_language(self):
        self.strings['Machines'] = entry('虚拟机', 'Machines', extra={'ja': {'stringUnit': {'state': 'translated', 'value': 'マシン'}}})
        issues, _ = self.run_check()
        self.assertEqual(issues, ["Localizable: unsupported language ja: 'Machines'"])

    def test_source_language_must_be_english(self):
        self.write(self.infoplist_catalog, {'CFBundleName': entry('x', 'x')}, source_language='zh-Hans')
        issues, _ = self.run_check()
        self.assertEqual(issues, ["InfoPlist: source language is 'zh-Hans', expected 'en'"])

    def test_infoplist_stale_and_missing(self):
        self.info_plist.write_bytes(plistlib.dumps({'CFBundleDisplayName': 'x'}))
        issues, _ = self.run_check()
        self.assertEqual(issues, ["InfoPlist: stale: 'CFBundleName' is not in the Info.plist template",
                                  "InfoPlist: missing: 'CFBundleDisplayName'"])

    def test_repository_catalogs_pass(self):
        issues, summary = module.run(module.DEFAULT_SOURCES, module.DEFAULT_CATALOG,
                                     module.DEFAULT_INFOPLIST_CATALOG, module.DEFAULT_INFO_PLIST)
        self.assertEqual(issues, [], summary)
        catalog = json.loads(module.DEFAULT_CATALOG.read_text())
        languages = {language for value in catalog['strings'].values() for language in value['localizations']}
        self.assertEqual(languages, {'en', 'zh-Hans'})


if __name__ == '__main__':
    unittest.main()
