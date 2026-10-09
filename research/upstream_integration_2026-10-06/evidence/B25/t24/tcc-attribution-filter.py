"""Read log --style ndjson; emit only known identity fields, never location text."""
import json, re, sys
actors = re.compile(r'com\.vphone\.[A-Za-z0-9_.-]+|vphone-(?:cli|vm|launchpad(?:-launcher)?)')
roles = re.compile(r'(?P<role>responsible|requesting|accessing|client)\s*[=:]\s*\{(?P<body>[^}]*)\}', re.I)
field = re.compile(r'\b(identifier|pid|auid|euid|binary_path)\s*[=:]\s*([^,;}\n]+)')
for line in sys.stdin:
    try:
        event = json.loads(line)
    except ValueError:
        continue
    message = event.get('eventMessage', '')
    names = sorted(set(actors.findall(message)))
    if not names or not any(word in message.lower() for word in ('auth', 'attribut', 'responsib', 'request', 'access', 'client')):
        continue
    identities = []
    for match in roles.finditer(message):
        values = {'role': match.group('role').lower()}
        for key, value in field.findall(match.group('body')):
            value = value.strip().strip('"')
            if key in ('pid', 'auid', 'euid'):
                if value.isdigit(): values[key] = int(value)
            elif key == 'identifier' and re.fullmatch(r'[A-Za-z0-9_.-]+', value):
                values[key] = value
            elif key == 'binary_path' and '/vphone-' in value and value.startswith('/'):
                values[key] = value
        identities.append(values)
    print(json.dumps({'timestamp': event.get('timestamp'), 'processID': event.get('processID'),
                      'processImagePath': event.get('processImagePath'),
                      'subsystem': event.get('subsystem'), 'category': event.get('category'),
                      'actors': names, 'identities': identities,
                      'authorization_event': 'auth' in message.lower()}, sort_keys=True), flush=True)
