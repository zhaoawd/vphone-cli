#!/usr/bin/env python3
"""Stage and verify the portable Mach-O closure of bundled host executables.

Guest iOS payloads and interpreter/script dependencies have separate validators.
No executable is launched while inspecting or staging its Mach-O dependencies.
"""
import argparse
import os
import plistlib
from pathlib import Path
import shutil
import subprocess

HOST_EXECUTABLES = (
    'Contents/MacOS/vphone-cli', 'Contents/MacOS/vphone-vm', 'Contents/MacOS/ldid',
    'Contents/MacOS/vphone-launchpad', 'Contents/MacOS/vphone-launchpad-launcher',
    'Contents/Resources/.tools/bin/trustcache', 'Contents/Resources/.tools/bin/insert_dylib',
    'Contents/Resources/.tools/bin/zstd', 'Contents/Resources/.tools/bin/xz',
)


def output(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True)


def system_library(value):
    path = Path(value)
    return path.is_absolute() and '..' not in path.parts and (
        value.startswith('/usr/lib/') or value.startswith('/System/Library/'))


def load_commands(path):
    dependencies = []
    rpaths = []
    identifier = None
    command = None
    for line in output('otool', '-l', path).splitlines():
        words = line.strip().split()
        if len(words) == 2 and words[0] == 'cmd':
            command = words[1]
        elif line.strip().startswith('name ') and command in (
            'LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB',
            'LC_LOAD_UPWARD_DYLIB', 'LC_LAZY_LOAD_DYLIB', 'LC_ID_DYLIB',
        ):
            value = line.strip()[5:].rsplit(' (offset ', 1)[0]
            if command == 'LC_ID_DYLIB':
                identifier = value
            else:
                dependencies.append(value)
        elif line.strip().startswith('path ') and command == 'LC_RPATH':
            rpaths.append(line.strip()[5:].rsplit(' (offset ', 1)[0])
    return list(dict.fromkeys(dependencies)), list(dict.fromkeys(rpaths)), identifier


def host_roots(bundle):
    return [bundle / relative for relative in HOST_EXECUTABLES if (bundle / relative).exists()]


def contained(path, bundle):
    if not path.resolve().is_relative_to(bundle.resolve()):
        raise ValueError(f'Native library escapes the bundle: {path}')


def resolve_dependency(value, source, root, rpaths):
    def expand(path):
        if path == '@loader_path':
            return source.parent
        if path == '@executable_path':
            return root.parent
        if path.startswith('@loader_path/'):
            return source.parent / path[len('@loader_path/'):]
        if path.startswith('@executable_path/'):
            return root.parent / path[len('@executable_path/'):]
        if path.startswith('/'):
            return Path(path)
        return None
    candidates = []
    if value.startswith('@rpath/'):
        for rpath in rpaths:
            base = expand(rpath)
            if base is not None:
                candidates.append(base / value[len('@rpath/'):])
    else:
        candidate = expand(value)
        if candidate is not None:
            candidates.append(candidate)
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise ValueError(f'Unresolved dependency in {source}: {value}')


def check_native_dependencies(bundle):
    bundle = bundle.resolve()
    roots = host_roots(bundle)
    pending = [(path, path) for path in roots]
    frameworks = bundle / 'Contents/Frameworks'
    unvisited_libraries = list(frameworks.glob('*.dylib')) if frameworks.exists() else []
    seen = set()
    report = {}
    while pending or unvisited_libraries:
        if not pending:
            library = unvisited_libraries.pop().resolve()
            if any(path == library for path, _ in seen):
                continue
            # Unreferenced packaged libraries must be safe for every named
            # host executable; referenced libraries retain their actual root.
            pending.extend((library, root) for root in roots)
            continue
        path, executable = pending.pop()
        contained(path, bundle)
        path = path.resolve()
        key = (path, executable)
        if key in seen:
            continue
        seen.add(key)
        dependencies, rpaths, identifier = load_commands(path)
        if identifier is not None and identifier != '@rpath/' + path.name:
            raise ValueError(f'Nonportable library identifier in {path}: {identifier}')
        for rpath in rpaths:
            if system_library(rpath):
                continue
            for token, directory in (('@loader_path', path.parent),
                                     ('@executable_path', executable.parent)):
                if rpath == token or rpath.startswith(token + '/'):
                    contained(directory / rpath[len(token):].lstrip('/'), bundle)
                    break
            else:
                raise ValueError(f'Nonportable rpath in {path}: {rpath}')
        for value in dependencies:
            if system_library(value):
                continue
            if not value.startswith('@loader_path/'):
                raise ValueError(f'External dependency in {path}: {value}')
            dependency = path.parent / value[len('@loader_path/'):]
            contained(dependency, bundle)
            if not dependency.is_file():
                raise ValueError(f'Unresolved dependency in {path}: {value}')
            required_arches = set(output('lipo', '-archs', path).split())
            actual_arches = set(output('lipo', '-archs', dependency).split())
            if not required_arches <= actual_arches:
                raise ValueError(f'Missing architecture in {dependency}: {required_arches - actual_arches}')
            pending.append((dependency, executable))
        subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True)
        report[str(path.relative_to(bundle))] = {
            'dependencies': dependencies, 'rpaths': rpaths, 'identifier': identifier,
        }
    if not report:
        raise ValueError(f'No host Mach-O executables found in {bundle}')
    return report


def stage_native_dependencies(bundle):
    bundle = bundle.resolve()
    frameworks = bundle / 'Contents/Frameworks'
    destinations = {}
    source_commands = {}
    dependency_plans = {}
    visited_contexts = set()
    signed = set()

    def stage(source, destination, root, inherited=()):
        source = source.resolve()
        key = (source, destination)
        contained(destination, bundle)
        if destination.resolve().is_relative_to((bundle / 'Contents/Helpers').resolve()):
            raise ValueError(f'Nested helper code is immutable during outer staging: {destination}')
        # Keep the original commands even when source and destination are the
        # same file; subsequent roots must not inspect already rewritten loads.
        if source not in source_commands:
            source_commands[source] = load_commands(source)
        dependencies, rpaths, identifier = source_commands[source]
        expanded_rpaths = []
        for rpath in rpaths:
            if rpath == '@loader_path':
                expanded_rpaths.append(str(source.parent))
            elif rpath == '@executable_path':
                expanded_rpaths.append(str(root.parent))
            elif rpath.startswith('@loader_path/'):
                expanded_rpaths.append(str(source.parent / rpath[len('@loader_path/'):]))
            elif rpath.startswith('@executable_path/'):
                expanded_rpaths.append(str(root.parent / rpath[len('@executable_path/'):]))
            else:
                expanded_rpaths.append(rpath)
        search_rpaths = list(dict.fromkeys([*expanded_rpaths, *inherited]))
        resolved = [(value, resolve_dependency(value, source, root, search_rpaths))
                    for value in dependencies if not system_library(value)]
        first_visit = key not in dependency_plans
        if not first_visit and dependency_plans[key] != resolved:
            raise ValueError(f'Conflicting dependency resolution across host roots: {source} (root {root})')
        dependency_plans[key] = resolved
        context = (source, destination, root, tuple(search_rpaths))
        if context in visited_contexts:
            return
        visited_contexts.add(context)
        for value, dependency in resolved:
            if dependency.is_relative_to(bundle):
                target = dependency
            else:
                target = frameworks / dependency.name
                previous = destinations.get(target)
                if previous is not None and previous != dependency:
                    raise ValueError(f'Conflicting native library name: {dependency.name}')
                if previous is None and target.exists() and target.read_bytes() != dependency.read_bytes():
                    raise ValueError(f'Conflicting native library contents: {target}')
                destinations[target] = dependency
                if not target.exists():
                    frameworks.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(dependency, target)
                    target.chmod(target.stat().st_mode | 0o200)
            stage(dependency, target, root, search_rpaths)
            if first_visit:
                replacement = '@loader_path/' + os.path.relpath(target, destination.parent)
                subprocess.run(['install_name_tool', '-change', value, replacement, str(destination)], check=True)
        if not first_visit:
            return
        if identifier is not None:
            subprocess.run(['install_name_tool', '-id', '@rpath/' + destination.name, str(destination)], check=True)
        for rpath in rpaths:
            if not system_library(rpath):
                subprocess.run(['install_name_tool', '-delete_rpath', rpath, str(destination)], check=True)
        signed.add(destination)

    for root in host_roots(bundle):
        stage(root, root, root)
    # codesign treats CFBundleExecutable as the app: sign it last so its
    # resource seal contains the final signatures of all nested host tools.
    info_path = bundle / 'Contents/Info.plist'
    main_executable = None
    if info_path.is_file():
        info = plistlib.loads(info_path.read_bytes())
        if isinstance(info.get('CFBundleExecutable'), str):
            main_executable = bundle / 'Contents/MacOS' / info['CFBundleExecutable']
    for path in sorted(signed, key=lambda item: (item == main_executable, str(item))):
        subprocess.run(['codesign', '--force', '--sign', '-',
                        '--preserve-metadata=entitlements,identifier,flags', str(path)], check=True)
    return check_native_dependencies(bundle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--check', action='store_true', help='Read-only inspection; reject external dependencies')
    args = parser.parse_args()
    report = check_native_dependencies(args.bundle) if args.check else stage_native_dependencies(args.bundle)
    print(f'Portable host Mach-O closure verified: {len(report)} signed images')


if __name__ == '__main__':
    main()
