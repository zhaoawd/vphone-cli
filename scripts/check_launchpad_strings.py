#!/usr/bin/env python3
"""Check the Launchpad string catalogs against the Launchpad Swift sources.

SwiftPM does not extract strings, so this is an approximate check over string
literals at localizable call sites (Text, Button, Label, TableColumn,
String(localized:), ...). Rules:

1. every catalog key appears in the sources (otherwise: stale);
2. every literal at a localizable call site is a catalog key (otherwise: missing);
3. every key has a zh-Hans value whose state is `translated` or `needs_review`;
4. placeholders agree in number and type between the key and each value;
5. the catalogs use only the configured languages (en, zh-Hans).

InfoPlist.xcstrings is checked against the Info.plist template the build
script installs.
"""
import argparse
import json
from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ('en', 'zh-Hans')
SOURCE_LANGUAGE = 'en'
ACCEPTED_STATES = ('translated', 'needs_review')
DEFAULT_SOURCES = (ROOT / 'sources/VPhoneLaunchpad', ROOT / 'sources/VPhoneLaunchpadKit')
DEFAULT_CATALOG = ROOT / 'sources/VPhoneLaunchpad/Localizable.xcstrings'
DEFAULT_INFOPLIST_CATALOG = ROOT / 'sources/VPhoneLaunchpad/InfoPlist.xcstrings'
DEFAULT_INFO_PLIST = ROOT / 'sources/VPhoneLaunchpad-Info.plist'

# Call sites whose first unlabeled string literal is a localization key.
CALL_SITE = re.compile(
    r'(?<![\w])(?:Text|Button|Label|LabeledContent|Toggle|Menu|Section|TableColumn|ContentUnavailableView|'
    r'LocalizedStringKey|LocalizedStringResource|navigationTitle|help|alert|confirmationDialog)'
    r'\(\s*(?=")'
)
LOCALIZED = re.compile(r'String\(\s*localized:\s*(?=")')
SPECIFIER = re.compile(r'%(?:\d+\$)?(@|lld|ld|d|lu|u|lf|f|s)')
INFO_PLIST_LOCALIZABLE = re.compile(r'^(CFBundleName|CFBundleDisplayName|NS\w+UsageDescription)$')


# MARK: - Swift literals

def read_literal(text, start):
    """Parse the Swift string literal whose opening quote is at `start`.

    Returns (value, end): `value` has each interpolation replaced by `%@`
    and simple escapes resolved; `end` is the index after the closing quote.
    Nested string literals inside interpolations are skipped.
    """
    assert text[start] == '"'
    out = []
    i = start + 1
    while i < len(text):
        c = text[i]
        if c == '"':
            return ''.join(out), i + 1
        if c == '\n':
            raise ValueError('unterminated string literal')
        if c == '\\':
            nxt = text[i + 1]
            if nxt == '(':
                i = skip_interpolation(text, i + 2)
                out.append('%@')
                continue
            if nxt == 'u' and text[i + 2] == '{':
                close = text.index('}', i + 3)
                out.append(chr(int(text[i + 3:close], 16)))
                i = close + 1
                continue
            out.append({'n': '\n', 't': '\t', '0': '\0', '"': '"', "'": "'", '\\': '\\'}.get(nxt, nxt))
            i += 2
            continue
        out.append(c)
        i += 1
    raise ValueError('unterminated string literal')


def skip_interpolation(text, i):
    """Index after the `)` closing an interpolation that starts at `i`."""
    depth = 1
    while i < len(text):
        c = text[i]
        if c == '"':
            _, i = read_literal(text, i)
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError('unterminated interpolation')


def normalized(key):
    """A key with every format specifier written as `%@`, for comparing a
    source literal (whose interpolation types are unknown here) with a key."""
    return SPECIFIER.sub('%@', key.replace('%%', '\0'))


def specifiers(value):
    return sorted(m.group(1) for m in SPECIFIER.finditer(value.replace('%%', '')))


def extract_literals(source_dirs):
    """{normalized key: [(path, line, literal)]} for every localizable literal."""
    found = {}
    for directory in source_dirs:
        for path in sorted(Path(directory).rglob('*.swift')):
            text = path.read_text(encoding='utf-8')
            for pattern in (CALL_SITE, LOCALIZED):
                for match in pattern.finditer(text):
                    literal, _ = read_literal(text, match.end())
                    line = text.count('\n', 0, match.start()) + 1
                    found.setdefault(normalized(literal), []).append((path, line, literal))
    return found


# MARK: - Catalogs

def localizations(entry):
    """{language: [values]}; a plural or device variation yields several."""
    result = {}
    for language, body in entry.get('localizations', {}).items():
        values = []
        if 'stringUnit' in body:
            values.append(body['stringUnit'])
        for variation in body.get('variations', {}).values():
            for case in variation.values():
                if 'stringUnit' in case:
                    values.append(case['stringUnit'])
        result[language] = values
    return result


def check_entries(catalog, label):
    """Language, translation and placeholder issues shared by both catalogs."""
    issues = []
    if catalog.get('sourceLanguage') != SOURCE_LANGUAGE:
        issues.append(f'{label}: source language is {catalog.get("sourceLanguage")!r}, expected {SOURCE_LANGUAGE!r}')
    for key, entry in sorted(catalog.get('strings', {}).items()):
        if entry.get('shouldTranslate') is False:
            continue
        units = localizations(entry)
        for language in sorted(set(units) - set(LANGUAGES)):
            issues.append(f'{label}: unsupported language {language}: {key!r}')
        for language in LANGUAGES:
            if language == SOURCE_LANGUAGE and language not in units:
                continue  # The key itself is the English text.
            values = units.get(language, [])
            if not values or any(not unit.get('value') or unit.get('state') not in ACCEPTED_STATES for unit in values):
                issues.append(f'{label}: untranslated ({language}): {key!r}')
                continue
            if label == 'Localizable':
                for unit in values:
                    if specifiers(unit['value']) != specifiers(key):
                        issues.append(f'{label}: placeholder mismatch ({language}): {key!r} -> {unit["value"]!r}')
    return issues


def check_localizable(catalog, literals):
    issues = check_entries(catalog, 'Localizable')
    keys = catalog.get('strings', {})
    by_normalized = {normalized(key) for key in keys}
    for key in sorted(keys):
        if normalized(key) not in literals:
            issues.append(f'Localizable: stale: {key!r}')
    for form, sites in sorted(literals.items()):
        if form not in by_normalized:
            path, line, literal = sites[0]
            issues.append(f'Localizable: missing: {literal!r} ({path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}:{line})')
    return issues


def check_infoplist(catalog, info):
    issues = check_entries(catalog, 'InfoPlist')
    keys = set(catalog.get('strings', {}))
    for key in sorted(keys):
        if key not in info:
            issues.append(f'InfoPlist: stale: {key!r} is not in the Info.plist template')
    for key in sorted(info):
        if INFO_PLIST_LOCALIZABLE.match(key) and key not in keys:
            issues.append(f'InfoPlist: missing: {key!r}')
    return issues


def needs_review(catalog):
    return sum(1 for entry in catalog.get('strings', {}).values()
               for values in localizations(entry).values()
               for unit in values if unit.get('state') == 'needs_review')


def run(sources, catalog_path, infoplist_catalog_path, info_plist_path):
    literals = extract_literals(sources)
    catalog = json.loads(Path(catalog_path).read_text(encoding='utf-8'))
    infoplist_catalog = json.loads(Path(infoplist_catalog_path).read_text(encoding='utf-8'))
    info = plistlib.loads(Path(info_plist_path).read_bytes())
    issues = check_localizable(catalog, literals) + check_infoplist(infoplist_catalog, info)
    summary = (f'Launchpad strings: {len(catalog.get("strings", {}))} keys, {len(literals)} source literals, '
               f'{len(infoplist_catalog.get("strings", {}))} Info.plist keys, languages {", ".join(LANGUAGES)}; '
               f'{len(issues)} issues; needs_review: {needs_review(catalog) + needs_review(infoplist_catalog)}')
    return issues, summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--sources', type=Path, nargs='+', default=list(DEFAULT_SOURCES))
    parser.add_argument('--catalog', type=Path, default=DEFAULT_CATALOG)
    parser.add_argument('--infoplist-catalog', type=Path, default=DEFAULT_INFOPLIST_CATALOG)
    parser.add_argument('--info-plist', type=Path, default=DEFAULT_INFO_PLIST)
    args = parser.parse_args(argv)
    issues, summary = run(args.sources, args.catalog, args.infoplist_catalog, args.info_plist)
    for issue in issues:
        print(issue)
    print(summary)
    return 1 if issues else 0


if __name__ == '__main__':
    sys.exit(main())
