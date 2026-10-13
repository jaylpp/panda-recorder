#!/usr/bin/env python3
"""Create the Finder layout for the mounted writable installer image.
Requires Pillow, ds-store and mac-alias.
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
from ds_store import DSStore
from mac_alias import Alias

root = Path(sys.argv[1])
background = root / '.background'
background.mkdir(exist_ok=True)
scale = 2
image = Image.new('RGB', (720 * scale, 440 * scale), '#f6f7fb')
draw = ImageDraw.Draw(image)
font_path = '/System/Library/Fonts/STHeiti Medium.ttc'
def text(value, y, size, color):
    font = ImageFont.truetype(font_path, size * scale)
    draw.text((360 * scale, y * scale), value, font=font, fill=color, anchor='mm')
text('安装熊猫录屏', 60, 26, '#242735')
text('拖入「应用程序」即可安装', 350, 17, '#606675')
# Arrow between the two Finder icons.
draw.line([(328 * scale, 205 * scale), (392 * scale, 205 * scale)], fill='#9ca5b5', width=3 * scale)
draw.line([(380 * scale, 193 * scale), (392 * scale, 205 * scale), (380 * scale, 217 * scale)], fill='#9ca5b5', width=3 * scale)
path = background / 'installer.png'
image.resize((720, 440), Image.Resampling.LANCZOS).save(path)
with DSStore.open(str(root / '.DS_Store'), 'w+') as store:
    store['.']['bwsp'] = {
        'ShowStatusBar': False, 'ShowToolbar': False, 'ShowSidebar': False,
        'ShowPathbar': False, 'ShowTabView': False,
        'WindowBounds': '{{200, 160}, {720, 440}}', 'SidebarWidth': 0,
    }
    store['.']['icvp'] = {
        'viewOptionsVersion': 1, 'backgroundType': 2,
        'backgroundImageAlias': Alias.for_file(str(path)).to_bytes(),
        'backgroundColorRed': 1.0, 'backgroundColorGreen': 1.0, 'backgroundColorBlue': 1.0,
        'scrollPositionX': 0.0, 'scrollPositionY': 0.0,
        'iconSize': 100.0, 'textSize': 14.0, 'gridSpacing': 100.0,
        'gridOffsetX': 0.0, 'gridOffsetY': 0.0, 'labelOnBottom': True,
        'arrangeBy': 'none', 'showIconPreview': True, 'showItemInfo': False,
    }
    store['.']['vSrn'] = ('long', 1)
    store['.']['icvl'] = ('type', b'icnv')
    store['熊猫录屏.app']['Iloc'] = (180, 205)
    store['应用程序']['Iloc'] = (540, 205)
