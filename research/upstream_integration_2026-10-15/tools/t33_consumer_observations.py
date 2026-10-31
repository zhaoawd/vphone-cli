"""Additional EXP observations; no VM start, approval or request transport."""
import base64

from t32_t33_runtime_evidence import complete_file_digest, settings_build_evidence


def collect(call, rpc, output, result, *, expected_build, base_collect):
    base_passed = base_collect(call, rpc, output, result)
    observations = result['observations']
    try:
        path = '/private/xarts/AA.gl'
        reply = rpc('files.read', dict(path=path, binary=True))
        result['completeGigalockerAfterUnlockAttempt'] = complete_file_digest(reply, path)
        observations['completeGigalockerAfterUnlockAttempt'] = dict(state='passed')
    except Exception as error:
        observations['completeGigalockerAfterUnlockAttempt'] = dict(state='failed', error=str(error))
    try:
        rpc('apps.open_url', dict(bundle_id='com.apple.Preferences', url='prefs:root=General&path=About'))
        before = rpc('apps.foreground', {})
        description = rpc('ui.describe', {})
        after = rpc('apps.foreground', {})
        evidence = settings_build_evidence(before, description, after, expected_build)
        # The validators require a later visual review. Saving the actual image
        # does not turn this collector's result into runtime acceptance.
        with (output / 'settings-about.jpg').open('xb') as stream:
            stream.write(base64.b64decode(description['screenshot']['data'], validate=True))
        result['settingsBuildEvidence'] = evidence
        observations['settingsBuild'] = dict(state='passed', visualReviewRequired=True)
    except Exception as error:
        observations['settingsBuild'] = dict(state='failed', error=str(error))
    finally:
        try:
            rpc('apps.terminate', dict(bundle_id='com.apple.Preferences'))
        except Exception as error:
            observations['settingsCleanup'] = dict(state='failed', error=str(error))
    return base_passed and all(row['state'] == 'passed' for row in observations.values())
