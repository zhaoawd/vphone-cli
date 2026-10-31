"""Interpret diskutil's explicit volume write-state fields."""


def volume_read_only(info):
    """Accept either volume flag; reject missing, malformed or conflicting flags.

    WritableMedia and Writable describe other properties and cannot replace a
    volume observation. This matches FirmwareInstalledReadback.volumeReadOnly.
    """
    keys = ('ReadOnlyVolume', 'WritableVolume')
    if (not isinstance(info, dict) or not any(key in info for key in keys)
            or any(key in info and type(info[key]) is not bool for key in keys)):
        raise ValueError('volume write state is unknown')
    readonly, writable = (info.get(key) for key in keys)
    if readonly is not None and writable is not None and readonly == writable:
        raise ValueError('volume write state contradicts itself')
    return readonly if readonly is not None else not writable
