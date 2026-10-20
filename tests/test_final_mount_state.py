"""Final staged mount qualification uses device and path observations."""
import copy
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from patchers import final_guest as reader


class FinalMountStateTests(unittest.TestCase):
    def test_writable_attachment_ignores_only_observed_allocation_counters(self):
        before = dict(ContainerReference='disk42', APFSContainerUUID='container', CapacityFree=2048,
            CapacityCeiling=4096, PhysicalStores=[dict(DeviceIdentifier='disk41s1', DiskUUID='store', Size=4096)],
            Volumes=[dict(DeviceIdentifier='disk42s1', APFSVolumeUUID='volume', CapacityInUse=1024, Roles=[])])
        after = copy.deepcopy(before)
        after['CapacityFree'] = 1024; after['Volumes'][0]['CapacityInUse'] = 2048
        self.assertEqual(reader.writable_attachment_state(before), reader.writable_attachment_state(after))
        self.assertEqual(before['CapacityFree'], 2048)
        self.assertEqual(before['Volumes'][0]['CapacityInUse'], 1024)
        changes = [dict(ContainerReference='disk99'), dict(APFSContainerUUID='other'),
            dict(CapacityCeiling=8192), dict(unknown='changed'),
            dict(PhysicalStores=[dict(DeviceIdentifier='disk99s1', DiskUUID='store', Size=4096)]),
            dict(PhysicalStores=[dict(DeviceIdentifier='disk41s1', DiskUUID='other', Size=4096)]),
            dict(Volumes=[])]
        for key, value in [('DeviceIdentifier', 'disk99s1'), ('APFSVolumeUUID', 'other'),
                           ('Roles', ['Data']), ('MountPoint', '/other'), ('unknown', 'changed')]:
            volume = copy.deepcopy(before['Volumes'][0]); volume[key] = value
            changes.append(dict(Volumes=[volume]))
        for changed in changes:
            with self.subTest(changed=changed):
                self.assertNotEqual(reader.writable_attachment_state(before),
                                    reader.writable_attachment_state(dict(before, **changed)))
        for volumes in [None, {}, [None]]:
            with self.subTest(volumes=volumes), self.assertRaises(ValueError):
                reader.writable_attachment_state(dict(before, Volumes=volumes))

    def test_only_explicit_unmounted_state_allows_missing_mountpoint(self):
        self.assertIsNone(reader.mount_point({'DeviceIdentifier':'disk42s1','Mounted':False},'disk42s1'))
        for value in ('','Not Mounted'):
            self.assertIsNone(reader.mount_point({'DeviceIdentifier':'disk42s1','MountPoint':value},'disk42s1'))
        for extra in [{}, {'Mounted':True}, {'Mounted':0}, {'Mounted':'false'},
                      {'Mounted':False,'MountPoint':'/another'}, {'Mounted':True,'MountPoint':''}]:
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                reader.mount_point(dict(DeviceIdentifier='disk42s1',**extra),'disk42s1')

    def test_legacy_explicit_mountpoint_and_modern_mounted_observations(self):
        for extra in [{}, {'Mounted':True}]:
            self.assertEqual(reader.mount_point(dict(DeviceIdentifier='disk42s1',MountPoint='/staged',**extra),
                                                 'disk42s1'),'/staged')

    def test_root_observation_must_match_device_path_and_readonly_state(self):
        root=Path('/staged/mnt1')
        valid=dict(DeviceIdentifier='disk42s1',MountPoint=str(root),Mounted=True,WritableVolume=False)
        for changed in [{'DeviceIdentifier':'disk99s1'}, {'MountPoint':'/elsewhere'},
                        {'Mounted':False}, {'WritableVolume':True}, {'WritableVolume':'false'}]:
            with self.subTest(changed=changed), patch.object(reader,'volume_info',return_value=dict(valid,**changed)):
                with self.assertRaises(ValueError): reader.require_mount(root,'disk42s1',True)
        with patch.object(reader,'volume_info',return_value=valid) as query:
            reader.require_mount(root,'disk42s1',True)
        query.assert_called_once_with(root)

    def test_overmounted_or_other_path_is_refused_before_unmount(self):
        with tempfile.TemporaryDirectory() as temp:
            work=Path(temp);root=work/'mnt1';root.mkdir();image=work/'Disk.img'
            container={'ContainerReference':'disk42','Volumes':[{'DeviceIdentifier':'disk42s1'}]}
            valid=dict(DeviceIdentifier='disk42s1',Mounted=True,MountPoint=str(root),WritableVolume=True)
            for observations in [[dict(valid,MountPoint='/elsewhere')],
                                 [valid,dict(valid,DeviceIdentifier='disk99s1')]]:
                with self.subTest(observations=observations), \
                     patch.dict(os.environ,CFW_HOST_MNT=str(work)), \
                     patch.object(reader.gate,'private_path',side_effect=lambda plan,p:Path(p)), \
                     patch.object(reader,'attachments',return_value=container), \
                     patch.object(reader,'volume_info',side_effect=observations), \
                     patch.object(reader.subprocess,'run') as execute:
                    with self.assertRaises(ValueError): reader.mount_roots(SimpleNamespace(),image,{'system'})
                    execute.assert_not_called()

    def test_writable_undo_mount_requires_actual_writable_path_observation(self):
        root=Path('/staged/mnt1')
        details=dict(DeviceIdentifier='disk42s1',Mounted=True,MountPoint=str(root),WritableVolume=True)
        with patch.object(reader,'volume_info',return_value=details):
            reader.require_mount(root,'disk42s1',False)
            with self.assertRaises(ValueError): reader.require_mount(root,'disk42s1',True)
