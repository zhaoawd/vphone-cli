"""Validate future runtime replies without issuing requests or accepting a VM run."""
import base64
import hashlib
import io
import math
import re

from PIL import Image


def complete_file_digest(reply, path):
    if (reply.get('path') != path or reply.get('encoding') != 'base64'
            or reply.get('truncated') is not False):
        raise ValueError('Complete binary file reply required')
    size = reply.get('size')
    if type(size) is not int or size <= 0:
        raise ValueError('Nonempty complete file size required')
    data = base64.b64decode(reply['content'], validate=True)
    if len(data) != size:
        raise ValueError('Decoded file length differs from complete size')
    return dict(path=path, bytes=size, sha256=hashlib.sha256(data).hexdigest())


def settings_pid(record):
    pid = record.get('pid')
    if (record.get('bundle_id') != 'com.apple.Preferences'
            or record.get('verified') is not True or type(pid) is not int or pid <= 0):
        raise ValueError('Verified Settings PID required')
    return pid


def settings_build_evidence(before, description, after, expected):
    if not isinstance(expected, str) or re.fullmatch(r'[0-9]+[A-Z][0-9]+[a-z]?', expected) is None:
        raise ValueError('Explicit expected build version required')
    pid = settings_pid(before)
    if (settings_pid(description['frontmost']) != pid or settings_pid(after) != pid
            or description.get('context_changed') is not False):
        raise ValueError('Settings process changed during observation')
    tree = description['elements']
    if (tree.get('source') != 'ax' or type(tree.get('pid')) is not int
            or tree['pid'] != pid or tree.get('truncated') is not False or tree.get('error')):
        raise ValueError('Complete AX tree from the same Settings PID required')
    matches = []
    token = re.compile(r'(?<![A-Za-z0-9_])' + re.escape(expected) + r'(?![A-Za-z0-9_])')
    for index, row in enumerate(tree['elements']):
        if row.get('visible') is not True:
            continue
        frame = row.get('frame', {})
        values = [frame.get(k) for k in ('x', 'y', 'width', 'height')]
        if (any(type(v) not in (int, float) or not math.isfinite(v) for v in values)
                or values[2] <= 0 or values[3] <= 0):
            continue
        for field in ('label', 'value'):
            text = row.get(field)
            if isinstance(text, str) and token.search(text):
                matches.append(dict(index=index, field=field, text=text, frame=dict(frame)))
    if not matches:
        raise ValueError('Expected build absent from visible AX labels and values')
    screenshot = description['screenshot']
    data = base64.b64decode(screenshot['data'], validate=True)
    if type(screenshot.get('bytes')) is not int or screenshot['bytes'] != len(data):
        raise ValueError('Screenshot byte count differs')
    with Image.open(io.BytesIO(data)) as image:
        image.load()
        dimensions = image.size
        if (image.format != 'JPEG' or screenshot.get('mime_type') != 'image/jpeg'
                or dimensions != (screenshot.get('width'), screenshot.get('height'))
                or min(dimensions) <= 0 or screenshot.get('coordinate_scale') != 1):
            raise ValueError('Screenshot format or dimensions differ')
    return dict(pid=pid, expectedBuildVersion=expected, visibleAXMatches=matches,
                screenshot=dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                                dimensions=list(dimensions)),
                visualReviewRequired=True, runtimeValidated=False,
                patchCausalityValidated=False)
