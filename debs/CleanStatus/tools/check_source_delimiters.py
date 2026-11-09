#!/usr/bin/env python3
"""Lexical delimiter check, not an Objective-C compiler."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
files=[p for folder in ('Animation','Sources','Headers','Hooks','LocalCleanStatusPrefs','Shared','LocalCleanStatusSystemActions') for p in (root/folder).rglob('*') if p.suffix in ('.h','.m','.xm','.c')]
for path in files:
    s=path.read_text(); stack=[]; i=0; line=1
    while i<len(s):
        c=s[i]
        if c=='\n': line+=1
        if s.startswith('//',i):
            end=s.find('\n',i);i=len(s) if end<0 else end;continue
        if s.startswith('/*',i):
            end=s.find('*/',i+2);assert end>=0,(str(path),'unterminated comment',line)
            line+=s[i:end+2].count('\n');i=end+2;continue
        if c in ('"',"'"):
            quote=c;i+=1
            while i<len(s):
                if s[i]=='\\':i+=2;continue
                if s[i]==quote:i+=1;break
                if s[i]=='\n':line+=1
                i+=1
            else:raise AssertionError((str(path),'unterminated string',line))
            continue
        if c in '({[':stack.append((c,line))
        if c in ')}]':
            assert stack and stack[-1][0]=={')':'(',']':'[','}':'{'}[c],(str(path),line,c,stack[-3:])
            stack.pop()
        i+=1
    assert not stack,(str(path),stack)
print('PASS source lexical delimiter matching:',len(files),'files; no iOS compilation performed')
