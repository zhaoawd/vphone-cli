# Python dependency locks

The macOS app and `scripts/setup_venv.sh` use the same environment manager. Supported locked environments are macOS ARM64 with CPython 3.13 or 3.14. Each `.lock` contains exact versions and SHA-256 hashes for the artifacts resolved on that platform. Its `.json` records download URLs, interpreter/platform identity and the hash of `requirements.txt` used during resolution. Linux and other Python/platform combinations are not covered by these locks; the existing Linux setup script remains outside this validation.

Use `make setup_venv` for the project environment. Set `VPHONE_HOST_PYTHON` to choose a supported interpreter and `VPHONE_VENV_DIR` to choose an environment location. For example:

```sh
VPHONE_HOST_PYTHON=/opt/homebrew/bin/python3.13 make setup_venv
```

The manager verifies a compatible environment before reusing it. Otherwise it builds a fresh generation beside the destination, installs pinned build tooling and hash-verified dependencies without build isolation, repairs the Keystone native library if needed, runs `pip check`, and checks actual ARM64 assembly/disassembly and required APIs. Only a verified generation becomes the public symlink. Virtual environments are never relocated after creation. Existing generations are retained; failure before publication preserves the previous environment. `vphone-cli setup --force` uses this same path instead of deleting the previous environment first.

The replacement of an existing real directory includes a rename before publication. Abrupt host/process termination during that interval is not covered by the current acceptance tests. These guarantees concern reported installation, verification and publication failures, not arbitrary power loss.

An explicit `VPHONE_PYTHON` must pass the complete locked probe; it no longer bypasses Keystone/version validation. To inspect a selected environment without installing anything:

```sh
.venv/bin/python3 scripts/check_python_runtime.py --locked --json
```

The JSON reports package versions, lock identity and version differences. Each generated environment also carries `vphone-environment.json`, including the source and output hashes of a repaired Keystone library. The app carries `build-dependencies.json` with Swift/Xcode/host identity, submodule revisions, bundled asset hashes and host-tool dynamic library references. A complete app still requires its documented host dependencies; these records do not establish execution on an untested machine.

To regenerate, resolve from the intended interpreter using `pip install --dry-run --ignore-installed --report REPORT.json -r requirements.txt pip==26.2.1`. Use a constraints file from the validated environment when preserving existing versions (`pip freeze --all` produces such a version snapshot). Then run:

```sh
python3 scripts/lock_python_dependencies.py REPORT.json dependencies/python-darwin-arm64-3.13.lock
```

Repeat with Python 3.14 for its lock. Review source/version/hash changes and validate fresh installation, reuse, failed installation/upgrade and runtime corruption before accepting a replacement lock. A resolution report alone is not environment acceptance. Do not copy a platform lock to another platform name.
