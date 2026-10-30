"""Generate rounded PreferenceLoader PNG assets only; no builds or device calls.
The 22% radius approximates the existing rounded settings-icon silhouette.
It is a measured matching default, not an asserted historical user value.
"""
from pathlib import Path
import json
from PIL import Image, ImageDraw, ImageChops

SETTINGS_SIZES = ((29, ''), (58, '@2x'), (87, '@3x'))
CORNER_RATIO = 0.22

def rounded_icon(source, size):
    image = source.convert('RGBA').resize((size, size), Image.Resampling.LANCZOS)
    # Supersample the mask, not the artwork: preserve pixels and soften only
    # the four outer corners. Transparent perimeter has no white/black matte.
    sample = 4
    mask = Image.new('L', (size * sample, size * sample), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size * sample - 1, size * sample - 1),
        radius=size * sample * CORNER_RATIO, fill=255)
    mask = mask.resize((size, size), Image.Resampling.LANCZOS)
    mask = mask.point(lambda a: 0 if a <= 3 else 255 if a >= 252 else a)
    image.putalpha(ImageChops.multiply(image.getchannel('A'), mask))
    return image

def validate_icon(path, size):
    with Image.open(path) as image:
        assert image.size == (size, size) and image.mode == 'RGBA', str(path)
        alpha = image.getchannel('A')
        assert all(alpha.getpixel(p) == 0 for p in (
            (0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1))), 'opaque corners'
        assert alpha.getpixel((size // 2, size // 2)) == 255, 'artwork changed'
        assert all(alpha.getpixel(p) == 255 for p in (
            (size // 2, 0), (size // 2, size - 1), (0, size // 2), (size - 1, size // 2))), 'padded/shrunken icon'
        assert any(0 < a < 255 for a in alpha.getdata()), 'aliased edge'
        return {'name': path.name, 'size': list(image.size), 'mode': image.mode,
                'corner_alpha': [0, 0, 0, 0], 'antialiased': True}

def write_rounded_icons(source, root):
    root = Path(root)
    resources = root / 'Prefs' / 'Resources'
    resources.mkdir(parents=True, exist_ok=True)
    rows = []
    for size, suffix in SETTINGS_SIZES:
        path = resources / f'icon{suffix}.png'
        rounded_icon(source, size).save(path)
        rows.append(validate_icon(path, size))
    path = root / 'icon-rounded-1024.png'
    rounded_icon(source, 1024).save(path)
    rows.append(validate_icon(path, 1024))
    return rows

if __name__ == '__main__':
    root = Path(__file__).resolve().parent
    # Keep the original square master and existing published DEBs intact.
    with Image.open(root / 'icon-1024.png') as source:
        result = write_rounded_icons(source, root)
    print(json.dumps(result, ensure_ascii=False, indent=2))
