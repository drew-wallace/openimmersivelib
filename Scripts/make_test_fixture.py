#!/usr/bin/env python3
"""Wrap a pinned MVC conformance stream in MKV, preserving B-frame PTS order.
This creates test artifacts only; production MKV parsing uses libavformat.
"""
from pathlib import Path
import re, struct, subprocess, json

root = Path(__file__).resolve().parents[1]
edge = root/'Vendor/edge264-mvc'
stream = edge/'tests/conformance/mvc/MVCDS-5.264'
if not (edge/'frame_info').exists():
    subprocess.run(['make','frame_info'],cwd=edge,check=True)
lines = subprocess.check_output([edge/'frame_info',stream],text=True).splitlines()
order = {}
hashes = []
for line in lines:
    m = re.fullmatch(r'view (\d) poc (-?\d+) decode_order (\d+) display_order (\d+) flags (\d+) (\d+)x(\d+) ([0-9a-f]+)',line)
    if not m: continue
    view,poc,decode,display,flags,w,h,digest = m.groups()
    if view=='0': order[int(decode)//2] = int(display)
    hashes.append({'view':int(view),'display':int(display),'hash':digest})
width,height=int(w),int(h)
nals=[x.rstrip(b'\0') for x in re.split(b'\x00\x00\x00?\x01',stream.read_bytes()) if x]
sps=[n for n in nals if n[0]&31==7]
pps=[n for n in nals if n[0]&31==8]
avcc=bytes([1,sps[0][1],sps[0][2],sps[0][3],255,224|len(sps)])
avcc+=b''.join(struct.pack('>H',len(n))+n for n in sps)+bytes([len(pps)])+b''.join(struct.pack('>H',len(n))+n for n in pps)
groups=[]; group=[]; has_picture=False
for nal in nals:
    if nal[0]&31==14 and has_picture:
        groups.append(group);group=[];has_picture=False
    group.append(nal)
    if nal[0]&31 in (1,5): has_picture=True
if group: groups.append(group)
assert len(groups)==len(order), (len(groups),len(order))

def vint(n):
    for size in range(1,9):
        if n < (1<<(7*size))-1: return ((1<<(7*size))|n).to_bytes(size,'big')
    raise ValueError(n)
def element(identifier,payload):
    key=bytes.fromhex(identifier)
    return key+vint(len(payload))+payload
def number(identifier,value): return element(identifier,value.to_bytes(max(1,(value.bit_length()+7)//8),'big'))
def text(identifier,value): return element(identifier,value.encode())
def floating(identifier,value): return element(identifier,struct.pack('>d',value))

header=element('1a45dfa3',number('4286',1)+number('42f7',1)+number('42f2',4)+number('42f3',8)+text('4282','matroska')+number('4287',4)+number('4285',2))
info=element('1549a966',number('2ad7b1',1000000)+floating('4489',len(groups)*1000/24)+text('4d80','MVCVision tests')+text('5741','MVCVision tests'))
video=element('ae',number('d7',1)+number('73c5',1)+number('83',1)+text('86','V_MPEG4/ISO/AVC')+element('63a2',avcc)+number('23e383',41666667)+element('e0',number('b0',width)+number('ba',height)))
wave=struct.pack('<HHIIHHHHI',0xfffe,6,48000,48000*12,12,16,22,16,0x3f)+bytes.fromhex('0100000000001000800000aa00389b71')
audio=element('ae',number('d7',2)+number('73c5',2)+number('83',2)+text('86','A_MS/ACM')+element('63a2',wave)+element('e1',floating('b5',48000)+number('9f',6)+number('6264',16)))
blocks=b''
for index,group in enumerate(groups):
    pts=round(order[index]*1000/24)
    packet=b''.join(struct.pack('>I',len(n))+n for n in group)
    blocks+=element('a3',b'\x81'+struct.pack('>h',pts)+bytes([128 if index==0 else 0])+packet)
    # One PCM block per presentation interval, interleaved in file order.
    # Silence here validates decoding and channel structure; the app's test tones
    # validate audible routing separately.
    blocks+=element('a3',b'\x82'+struct.pack('>h',index*1000//24)+b'\x80'+b'\0'*(2000*6*2))
segment=info+element('1654ae6b',video+audio)+element('1f43b675',number('e7',0)+blocks)
out=root/'.build/fixtures';out.mkdir(parents=True,exist_ok=True)
(out/'mvc-bframes.mkv').write_bytes(header+element('18538067',segment))
base_blocks=b''
for index,group in enumerate(groups):
    packet=b''.join(struct.pack('>I',len(n))+n for n in group if n[0]&31 not in (14,15,20))
    pts=round(order[index]*1000/24)
    base_blocks+=element('a3',b'\x81'+struct.pack('>h',pts)+bytes([128 if index==0 else 0])+packet)
base_segment=info+element('1654ae6b',video)+element('1f43b675',number('e7',0)+base_blocks)
(out/'avc-only.mkv').write_bytes(header+element('18538067',base_segment))

(out/'mvc-bframes-reference.json').write_text(json.dumps({'frames':len(groups),'hashes':hashes,'display_order_by_packet':order},indent=2))
print(out/'mvc-bframes.mkv')
