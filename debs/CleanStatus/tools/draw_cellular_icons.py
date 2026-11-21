#!/usr/bin/env python3
"""Original CleanStatus double-SIM glyph. No upstream artwork or binary is embedded."""
from pathlib import Path
from PIL import Image,ImageDraw
ROOT=Path(__file__).resolve().parents[1]
def icon(size,setting):
    q=4;n=size*q;im=Image.new('RGBA',(n,n),(0,0,0,0));d=ImageDraw.Draw(im)
    def pts(v):return [(round(x*n),round(y*n)) for x,y in v]
    if setting:d.rounded_rectangle((0,0,n-1,n-1),radius=n*.23,fill=(38,163,113,255))
    color=(255,255,255,255);stroke=max(2,round(n*.045))
    # Two SIM outlines, each with a cut top-right corner, not copied from either upload.
    for x,y in ((.18,.18),(.43,.34)):
        polygon=pts([(x,y),(x+.23,y),(x+.34,y+.11),(x+.34,y+.46),(x,y+.46),(x,y)])
        d.line(polygon,fill=color,width=stroke,joint='curve')
        d.rounded_rectangle((round((x+.08)*n),round((y+.21)*n),round((x+.25)*n),round((y+.35)*n)),radius=stroke/2,outline=color,width=max(1,stroke//2))
    return im.resize((size,size),Image.Resampling.LANCZOS)
if __name__=='__main__':
    target=ROOT/'LocalCleanStatusDataSwitch/Resources';pref=ROOT/'LocalCleanStatusPrefs/Resources'
    for scale,suffix in ((1,''),(2,'@2x'),(3,'@3x')):
        icon(50*scale,False).save(target/f'DataSwitch{suffix}.png')
        image=icon(29*scale,True);image.save(target/f'SettingsIcon{suffix}.png');image.save(pref/f'CellularIcon{suffix}.png')
    print('Wrote 9 original PNG resources; no downloaded or uploaded artwork used.')
