import hashlib
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from patchers import component_signatures as signatures


def signed_macho(code=b'original', entitlements=None):
    limit=4096
    cd=bytearray(44+32)
    struct.pack_into('>IIIIIIIII',cd,0,0xfade0c02,len(cd),0x20000,0,44,0,0,1,limit)
    cd[36:40]=bytes([32,2,0,12])
    ent=plistlib.dumps(entitlements or {'test':True})
    blob=struct.pack('>II',0xfade7171,len(ent)+8)+ent
    size=28+len(cd)+len(blob)
    body=bytearray(limit)
    struct.pack_into('<IIIIIIII',body,0,0xfeedfacf,0x100000c,0,2,1,16,0,0)
    struct.pack_into('<IIII',body,32,0x1d,16,limit,size)
    body[256:256+len(code)]=code
    cd[44:]=hashlib.sha256(body).digest()
    return bytes(body)+struct.pack('>IIIIIII',0xfade0cc0,size,2,0,28,5,28+len(cd))+cd+blob


class ComponentSignatureTests(unittest.TestCase):
    def test_signing_preserves_code_and_reads_final_entitlements(self):
        with tempfile.TemporaryDirectory() as tmp:
            old,new=Path(tmp)/'old',Path(tmp)/'new'
            old.write_bytes(signed_macho())
            new.write_bytes(signed_macho(entitlements={'changed':True}))
            signatures.verify_signing(old,new)
            self.assertEqual(signatures.entitlements(new),[{'changed':True}])
            new.write_bytes(signed_macho(code=b'Original',entitlements={'changed':True}))
            with self.assertRaises(ValueError): signatures.verify_signing(old,new)

    def test_code_directory_slots_are_checked_against_final_pages(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'binary';path.write_bytes(signed_macho())
            requirements=signatures.changed_slots(path,path,[(256,1)])
            self.assertTrue(requirements)
            signatures.verify_slots(path,requirements)
            data=bytearray(path.read_bytes());data[256]=ord('X');path.write_bytes(data)
            with self.assertRaises(ValueError): signatures.verify_slots(path,requirements)

    def test_fat_first_signature_preserves_both_architectures(self):
        def fat(first,second):
            offset1=4096;offset2=12288
            second=bytearray(second);struct.pack_into('<I',second,8,2)
            if len(second)>4096: second[4168:4200]=hashlib.sha256(second[:4096]).digest()
            second=bytes(second)
            header=struct.pack('>II',0xcafebabe,2)+struct.pack('>IIIII',0x100000c,0,offset1,len(first),12)+struct.pack('>IIIII',0x100000c,2,offset2,len(second),12)
            return header+b'\0'*(offset1-len(header))+first+b'\0'*(offset2-offset1-len(first))+second
        with tempfile.TemporaryDirectory() as tmp:
            old,new=Path(tmp)/'old',Path(tmp)/'new'
            unsigned=bytearray(signed_macho()[:4096]);unsigned[16:24]=b'\0'*8;unsigned[32:48]=b'\0'*16
            old.write_bytes(fat(bytes(unsigned),bytes(unsigned)))
            new.write_bytes(fat(signed_macho(entitlements={'new':1}),signed_macho(entitlements={'new':1})))
            signatures.verify_signing(old,new)
            new.write_bytes(fat(signed_macho(code=b'changed!'),signed_macho()))
            with self.assertRaises(ValueError): signatures.verify_signing(old,new)

    def test_dsc_shared_page_has_composed_final_slot_hash(self):
        def dsc(code):
            data=bytearray(signed_macho(code))
            data[:16]=b'dyld_v1 arm64e'.ljust(16,b' ')
            struct.pack_into('<QQ',data,0x28,4096,len(data)-4096)
            data[4096+28+44:4096+28+76]=hashlib.sha256(data[:4096]).digest()
            return bytes(data)
        with tempfile.TemporaryDirectory() as tmp:
            before,first,final=[Path(tmp)/name for name in ('before','first','final')]
            before.write_bytes(dsc(b'00000000'));first.write_bytes(dsc(b'10000000'));final.write_bytes(dsc(b'10000001'))
            requirements=signatures.changed_slots(before,first,[(256,1)])
            signatures.verify_slots(final,requirements)
            data=bytearray(final.read_bytes());data[4096+28+44]^=1;final.write_bytes(data)
            with self.assertRaises(ValueError): signatures.verify_slots(final,requirements)

    def test_overlapping_signature_blobs_and_header_hash_table_refuse(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'binary'
            data=bytearray(signed_macho())
            # Two slots point to the same CodeDirectory.
            struct.pack_into('>I',data,4096+24,28)
            path.write_bytes(data)
            with self.assertRaises(ValueError): signatures.directories(path)
            data=bytearray(signed_macho())
            # A code slot cannot alias the CodeDirectory header.
            struct.pack_into('>I',data,4096+28+16,8)
            path.write_bytes(data)
            with self.assertRaises(ValueError): signatures.directories(path)

    def test_fat_cpu_identity_must_match_its_slice_header(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'binary'
            body=signed_macho()
            path.write_bytes(struct.pack('>IIIIIII',0xcafebabe,1,0x100000c,2,4096,len(body),12)+b'\0'*(4096-28)+body)
            with self.assertRaises(ValueError): signatures.layouts(path)

    def test_signer_requires_code_directory_for_each_fat_slice(self):
        def fat(second):
            first=signed_macho();offset=12288
            header=struct.pack('>II',0xcafebabe,2)+struct.pack('>IIIII',0x100000c,0,4096,len(first),12)+struct.pack('>IIIII',0x100000c,2,offset,len(second),12)
            return header+b'\0'*(4096-len(header))+first+b'\0'*(offset-4096-len(first))+second
        with tempfile.TemporaryDirectory() as tmp:
            before,after=Path(tmp)/'old',Path(tmp)/'new'
            second=bytearray(signed_macho());struct.pack_into('<I',second,8,2)
            second[4168:4200]=hashlib.sha256(second[:4096]).digest()
            before.write_bytes(fat(second))
            # Keep a well-formed entitlements-only SuperBlob on the second slice.
            ent=plistlib.dumps({'test':True});blob=struct.pack('>II',0xfade7171,len(ent)+8)+ent
            size=20+len(blob);body=second[:4096];struct.pack_into('<I',body,44,size)
            after.write_bytes(fat(body+struct.pack('>IIIII',0xfade0cc0,size,1,5,20)+blob))
            with self.assertRaises(ValueError): signatures.verify_signing(before,after)

    def test_signer_cannot_discard_non_signature_trailer(self):
        with tempfile.TemporaryDirectory() as tmp:
            old,new=Path(tmp)/'old',Path(tmp)/'new'
            old.write_bytes(signed_macho()+b'required trailer')
            new.write_bytes(signed_macho())
            with self.assertRaises(ValueError): signatures.verify_signing(old,new)

    def test_linkedit_resize_must_describe_actual_signature_layout(self):
        def binary(vmsize):
            data=bytearray(signed_macho());struct.pack_into('<II',data,16,2,88)
            command=bytearray(72);struct.pack_into('<II16sQQQQIIII',command,0,0x19,72,b'__LINKEDIT',0x100000000,vmsize,4096,len(data)-4096,1,1,0,0)
            data[48:120]=command;data[4168:4200]=hashlib.sha256(data[:4096]).digest();return data
        with tempfile.TemporaryDirectory() as tmp:
            old,new=Path(tmp)/'old',Path(tmp)/'new'
            old.write_bytes(binary(4096));new.write_bytes(binary(16384))
            signatures.verify_signing(old,new)
            new.write_bytes(binary(1<<40))
            with self.assertRaises(ValueError): signatures.verify_signing(old,new)

    def test_signer_cannot_promote_an_unknown_input_signature_structure(self):
        with tempfile.TemporaryDirectory() as tmp:
            old,new=Path(tmp)/'old',Path(tmp)/'new'
            data=bytearray(signed_macho());data[4096]=0
            old.write_bytes(data);new.write_bytes(signed_macho())
            with self.assertRaises(ValueError): signatures.verify_signing(old,new)

    def test_noncontiguous_code_directory_requires_supported_page_mapping(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'binary';data=bytearray(signed_macho());cd=4096+28
            data[cd+44:cd+44]=b'\0'*4
            struct.pack_into('>I',data,cd+4,80)
            struct.pack_into('>I',data,cd+8,0x20100)
            struct.pack_into('>I',data,cd+16,48)
            struct.pack_into('>I',data,4096+4,len(data)-4096)
            struct.pack_into('>I',data,4096+24,108)
            struct.pack_into('<I',data,44,len(data)-4096)
            data[cd+48:cd+80]=hashlib.sha256(data[:4096]).digest()
            path.write_bytes(data)
            signatures.verify_slots(path,signatures.changed_slots(path,path,[(256,1)]))
            struct.pack_into('>I',data,cd+44,72)
            path.write_bytes(data)
            with self.assertRaisesRegex(ValueError,'scatter'):
                signatures.directories(path)
