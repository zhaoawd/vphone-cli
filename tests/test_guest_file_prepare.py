"""Original capture runs real generation qualification; native mounting is isolated."""
import contextlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import unittest
from unittest.mock import patch

from tests import test_guest_file_originals as fixtures
from patchers import file_originals as originals,component_effects as effects


class GuestFilePrepareTests(unittest.TestCase):
    def setUp(self):
        self.o=fixtures.GuestFileOriginalTests();self.o.setUp();self.addCleanup(self.o.doCleanups)
        # Start with an ordinary new v5 transaction, before its first catalog.
        import cfw_disk_txn as txn
        record=txn.load_record(self.o.work)
        record.update(version=5,guestEvidenceRequired=True,runtimeImageEvidenceRequired=True)
        txn.save_record(self.o.work,record)

    def test_production_prepare_binds_sources_blobs_and_journal(self):
        @contextlib.contextmanager
        def native(image,workspace):
            self.assertEqual(workspace,Path(os.environ['CFW_HOST_MNT']))
            self.assertEqual(image.parent,self.o.work/'file-original-sources')
            yield self.o.root,lambda:None
        with patch('cache_systemos.cache_systemos',side_effect=shutil.copyfile),patch.object(originals,'mounted',side_effect=native):
            catalog=originals.prepare(self.o.f.plan,self.o.work)
        self.assertEqual(catalog,originals.load(self.o.f.plan,self.o.store))
        self.assertEqual(len(catalog['sources']),2)
        self.assertFalse((self.o.work/'file-original-sources').exists())
        self.assertEqual(catalog['members']['system:/usr/libexec/seputil']['state'],effects.state(self.o.binary))
        import cfw_disk_txn as txn
        self.assertEqual(txn.load_record(self.o.work)['fileOriginalsSHA256'],effects.digest(self.o.work/originals.FILENAME))

    def test_altered_source_or_profile_cannot_be_rebound_by_rehashing_catalog(self):
        catalog=self.o.catalog();catalog['sources'][0]['profile']='cryptex';self.o.save(catalog)
        with self.assertRaises(ValueError):originals.load(self.o.f.plan,self.o.store)
        catalog=self.o.catalog();catalog['members']['system:/usr/libexec/seputil']['state']['mode']=True;self.o.save(catalog)
        with self.assertRaisesRegex(ValueError,'metadata'):originals.load(self.o.f.plan,self.o.store)

    def query(self,image,commands,*,busy=False):
        state={'attached':False,'root':None}
        def query(argv,**kwargs):
            commands.append(argv)
            if argv[1]=='info':
                return plistlib.dumps({'images':([{'image-path':str(image),'system-entities':[
                    {'mount-point':state['root'],'dev-entry':'/dev/disk900s1'}]}] if state['attached'] else [])})
            if argv[1]=='attach':
                state.update(attached=True,root=argv[argv.index('-mountpoint')+1])
                return plistlib.dumps({'system-entities':[{'mount-point':state['root'],'dev-entry':'/dev/disk900s1'}]})
            if argv[1]=='detach':
                if busy:raise subprocess.CalledProcessError(16,argv)
                state['attached']=False;return b''
            raise AssertionError(argv)
        return query

    def test_native_source_mount_is_readonly_and_normally_detached(self):
        image=self.o.work/'source.dmg';image.write_bytes(b'image');commands=[]
        with patch.object(originals.subprocess,'check_output',side_effect=self.query(image,commands)), \
             patch.object(originals.final_guest,'require_mount') as checked, \
             patch.object(originals.os,'statvfs',return_value=type('VFS',(),{'f_flag':os.ST_RDONLY})()):
            with originals.mounted(image,self.o.work) as (root,recheck):
                self.assertTrue(root.exists());recheck()
            self.assertFalse(root.exists())
        self.assertIn('-readonly',next(argv for argv in commands if argv[1]=='attach'))
        self.assertEqual(commands[-1],['/usr/bin/hdiutil','detach','/dev/disk900s1'])
        self.assertTrue(all(call.args[-1] is True for call in checked.call_args_list))

    def test_busy_native_source_mount_preserves_attachment_and_directory(self):
        image=self.o.work/'source.dmg';image.write_bytes(b'image');commands=[]
        with patch.object(originals.subprocess,'check_output',side_effect=self.query(image,commands,busy=True)), \
             patch.object(originals.final_guest,'require_mount'), \
             patch.object(originals.os,'statvfs',return_value=type('VFS',(),{'f_flag':os.ST_RDONLY})()):
            with self.assertRaises(subprocess.CalledProcessError):
                with originals.mounted(image,self.o.work) as (root,recheck):pass
        self.assertTrue(root.exists());self.assertNotIn('-force',sum(commands,[]))


if __name__=='__main__':unittest.main()

class NormalSourceDetachTests(unittest.TestCase):
    def test_shared_source_detach_does_not_force_a_busy_mount(self):
        root=Path(__file__).resolve().parents[1]
        common=root/'scripts/lib/cfw_common.sh'
        command='source "$1"; mount() { print "source on /owned-source (read-only)"; }; probe() { print -r -- "$@"; }; cfw_detach_with /owned-source probe'
        result=subprocess.run(['/bin/zsh','-c',command,'test',str(common)],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.strip(),'detach /owned-source')
