"""Filter TCC/VM evidence before persistence; never output raw location messages."""
import argparse, json, re, sys
ROLES = re.compile(r'(responsible|requesting|accessing|client)\s*[=:]\s*\{([^}]*)\}', re.I)
FIELDS = re.compile(r'\b(identifier|pid|auid|euid|binary_path)\s*[=:]\s*([^,;}\n]+)')
ACTORS = re.compile(r'com\.vphone\.[A-Za-z0-9_.-]+|vphone-(?:cli|vm|launchpad(?:-launcher)?)')
STAMP = re.compile(r'\d{4}-\d{2}-\d{2}T[0-9:.+-]+Z?')

def integer(value):
    return value if type(value) is int and value >= 0 else None

def tcc(event, paths, identifiers):
    message = event.get('eventMessage', '')
    if not isinstance(message, str): return None
    actors = sorted(set(ACTORS.findall(message)))
    if not actors or not any(x in message.lower() for x in ('auth', 'attribut', 'responsib', 'request', 'access', 'client')): return None
    identities = []
    for role, body in ROLES.findall(message):
        values = {'role': role.lower()}
        for key, value in FIELDS.findall(body):
            value = value.strip().strip('"')
            if key in ('pid', 'auid', 'euid') and value.isdigit() and len(value) <= 10: values[key] = int(value)
            elif key == 'identifier' and value in identifiers: values[key] = value
            elif key == 'binary_path' and value in paths: values[key] = value
        identities.append(values)
    stamp = event.get('timestamp')
    return {'timestamp': stamp if isinstance(stamp, str) and STAMP.fullmatch(stamp) else None,
            'processID': integer(event.get('processID')), 'actors': [x for x in actors if x in identifiers],
            'identities': identities, 'authorization_event': 'auth' in message.lower()}

def vm(line):
    value = line.strip()
    if value.startswith('[location] got location:'): return '[location] location sample received'
    if re.fullmatch(r'\[location\] authorization status: [0-9]+', value): return value
    if value in ('[location] host location forwarding ready', '[location] started host location tracking',
                 '[location] stopped host location tracking', '[location] location sample received'): return value
    return None

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('tcc', 'vm'))
    parser.add_argument('--identities', help='Frozen allowlist JSON with paths and identifiers')
    args = parser.parse_args()
    allow = json.load(open(args.identities)) if args.identities else {'paths': [], 'identifiers': []}
    for line in sys.stdin:
        if args.mode == 'vm': result = vm(line)
        else:
            try: event = json.loads(line)
            except ValueError: continue
            if not isinstance(event, dict): continue
            result = tcc(event, set(allow['paths']), set(allow['identifiers']))
        if result is not None: print(json.dumps(result, sort_keys=True) if args.mode == 'tcc' else result, flush=True)

if __name__ == '__main__': main()
