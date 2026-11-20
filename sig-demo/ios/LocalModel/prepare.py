#!/usr/bin/env python3
# Copyright 2026 Sig Demo contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Explicit public source/model download. Never reads provider credentials."""
import argparse, hashlib, json, pathlib, struct, tarfile, urllib.request
import tempfile
HERE=pathlib.Path(__file__).resolve().parent

def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        while data:=f.read(8*1024*1024):h.update(data)
    return h.hexdigest()

def fetch(url,path,digest,size=None):
    if path.exists():
        if (size is None or path.stat().st_size==size) and sha(path)==digest:return
        raise RuntimeError('Existing cache file failed verification: '+path.name)
    temp=path.with_name(path.name+'.partial');path.parent.mkdir(parents=True,exist_ok=True)
    with urllib.request.urlopen(url,timeout=60) as response,temp.open('wb') as out:
        while data:=response.read(4*1024*1024):out.write(data)
    if (size is not None and temp.stat().st_size!=size) or sha(temp)!=digest:
        raise RuntimeError('Downloaded bytes failed verification: '+path.name)
    temp.rename(path)

def metadata(path):
    sizes={0:1,1:1,2:2,3:2,4:4,5:4,6:4,7:1,10:8,11:8,12:8}
    with path.open('rb') as f:
        def integer(fmt):return struct.unpack('<'+fmt,f.read(struct.calcsize('<'+fmt)))[0]
        def string(keep=True):
            count=integer('Q')
            if count>64*1024*1024:raise ValueError('Invalid GGUF string')
            if keep:return f.read(count).decode('utf8')
            f.seek(count,1)
        def value(kind,keep):
            if kind==8:return string(keep)
            if kind==9:
                element=integer('I');count=integer('Q')
                if count>2_000_000:raise ValueError('Invalid GGUF array')
                if element in sizes:f.seek(count*sizes[element],1)
                else:
                    for _ in range(count):value(element,False)
            elif kind in sizes:f.seek(sizes[kind],1)
            else:raise ValueError('Invalid GGUF type')
        if f.read(4)!=b'GGUF' or integer('I')!=3:raise ValueError('Expected GGUFv3')
        integer('Q');count=integer('Q');result={}
        if count>10000:raise ValueError('Invalid metadata count')
        for _ in range(count):
            key=string();kind=integer('I');keep=key in ['general.architecture','general.name','tokenizer.chat_template']
            v=value(kind,keep)
            if keep:result[key]=v
        return result

def prepare_legacy_source(root, pin):
    archive = root / 'Source' / 'llama.tar.gz'
    source = archive.parent / ('llama.cpp-' + pin['commit'])
    fetch(pin['archive_url'], archive, pin['archive_sha256'])
    if not source.exists():
        with tarfile.open(archive) as tar:
            tar.extractall(archive.parent, filter='data')
    # Verify existing extracted files against the pinned archive.
    with tarfile.open(archive) as tar:
        for member in tar:
            if member.isfile():
                target = archive.parent / member.name
                if target.is_symlink() or not target.is_file():
                    raise RuntimeError('Source member missing')
                if hashlib.sha256(tar.extractfile(member).read()).hexdigest() != sha(target):
                    raise RuntimeError('Source member changed')
    return source


def prepare_model(root, model):
    target = root / 'Models' / model['filename']
    url = f"https://huggingface.co/{model['repository']}/resolve/{model['revision']}/{model['filename']}"
    fetch(url, target, model['sha256'], model['bytes'])
    meta = metadata(target)
    template = meta.get('tokenizer.chat_template', '')
    if meta.get('general.architecture') != model['architecture'] or '<tool_call>' not in template or 'tools' not in template:
        raise RuntimeError('Unexpected architecture or missing native tool template')
    return {
        'id': model['id'], 'bytes': target.stat().st_size, 'sha256': model['sha256'],
        'architecture': meta['general.architecture'],
        'chat_template_sha256': hashlib.sha256(template.encode()).hexdigest(), 'tool_template': True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=pathlib.Path)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--models', action='store_true', help='Prepare weights and legacy llama.cpp source')
    modes.add_argument('--models-only', action='store_true', help='Prepare weights for the GDK iPhone build')
    args = parser.parse_args()
    root = args.root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    lock = json.loads((HERE / 'source.lock.json').read_text())
    if not args.models_only:
        print(prepare_legacy_source(root, lock['llama']))
    if args.models or args.models_only:
        models = [prepare_model(root, model) for model in lock['models']]
        with tempfile.NamedTemporaryFile('w', dir=root, delete=False) as receipt:
            json.dump({'models': models}, receipt, indent=2)
            receipt.write('\n')
        pathlib.Path(receipt.name).replace(root / 'MODELS.json')
        if args.models_only:
            print(root / 'Models')


if __name__ == '__main__':
    main()
