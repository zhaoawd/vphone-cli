"""Select this launch's log without accepting bytes from an earlier launch."""
import hashlib


def read_launch_serial(path, baseline, observed_running_at):
    info = path.stat()
    identity = dict(device=info.st_dev, inode=info.st_ino, birth=info.st_birthtime)
    previous = baseline.get('serialIdentity')
    if previous is not None and identity == previous:
        offset = baseline['serialOffset']
        assert info.st_size >= offset, 'Log shrank without a new file identity'
        data = path.read_bytes()
        if baseline.get('serialPrefixSHA256') is not None:
            assert hashlib.sha256(data[:offset]).hexdigest() == baseline['serialPrefixSHA256'], 'Previous log prefix changed'
        mode = 'same_file_append'
    elif baseline['observedAt'] <= info.st_birthtime <= observed_running_at:
        # Launchpad intentionally creates a new inode for a new launch. Its
        # creation must be between the saved stopped baseline and this observed
        # running instance. A later replacement cannot supply stop evidence.
        offset = 0
        data = path.read_bytes()
        mode = 'new_file_created_for_observed_launch'
    else:
        raise AssertionError('Log file is not tied to the observed launch')
    return data[offset:].decode(errors='replace'), dict(mode=mode, identity=identity, offset=offset,
        bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
