"""Writes the demo folders used for App Store screenshots.

make_demo_files.py <host-documents-dir> <cloud-root> <lang>
Local folders (device side) get real files; the cloud side gets empty
destination folders plus a few files that only exist on the server.
"""
import json, math, os, random, shutil, sys
from PIL import Image, ImageDraw, ImageFilter

docs, cloud = sys.argv[1], sys.argv[2]
random.seed(7)

def photo(path, hue):
    w, h = 1600, 1200
    img = Image.new('RGB', (w, h))
    d = ImageDraw.Draw(img)
    top = [(hue + 20) % 360, 70, 90]
    for y in range(h):
        t = y / h
        # sky → horizon gradient
        r = int(255 * (0.35 + 0.55 * (1 - t)) * (0.6 + 0.4 * math.cos(math.radians(hue))))
        g = int(255 * (0.45 + 0.45 * (1 - t)) * (0.6 + 0.4 * math.cos(math.radians(hue - 120))))
        b = int(255 * (0.55 + 0.4 * (1 - t)) * (0.6 + 0.4 * math.cos(math.radians(hue + 120))))
        d.line([(0, y), (w, y)], fill=(min(r, 255), min(g, 255), min(b, 255)))
    for i in range(3):  # hills
        base = int(h * (0.55 + 0.12 * i))
        pts = [(0, h)] + [(x, base - int(80 * math.sin(x / (180 + 60 * i) + i))) for x in range(0, w + 40, 40)] + [(w, h)]
        shade = 40 + 35 * i
        d.polygon(pts, fill=(shade, 70 + 30 * i, 60 + 10 * i))
    d.ellipse([w * 0.7, h * 0.12, w * 0.7 + 160, h * 0.12 + 160], fill=(255, 236, 190))
    img.filter(ImageFilter.GaussianBlur(1.2)).save(path, quality=88)

def text(path, body):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write(body)

lang = sys.argv[3] if len(sys.argv) > 3 else 'en'
all_names = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'shot_strings.json')))
names = all_names[lang]
# Only this language's demo folders on the device: the system folder picker
# shows them all and would push the wanted one below the fold. Languages also
# share names (Fotos, 照片…), so every run starts from fresh files.
for other in all_names.values():
    for key in ('photos', 'documents', 'work', 'music'):
        shutil.rmtree(os.path.join(docs, other[key]), ignore_errors=True)
if lang == 'zh':
    files = {
        'photos': [f'IMG_{n}.jpg' for n in (2041, 2042, 2057, 2063, 2088, 2104)],
        'documents': ['2026 家庭预算.xlsx', '房屋租赁合同.pdf', '旅行计划.md', '会议纪要 0925.docx'],
        'work': ['季度报告.key', '产品路线图.pdf', '设计稿/首页.png', '设计稿/图标.png'],
        'music': ['晨跑歌单.m3u', '吉他练习.m4a'],
    }
else:
    files = {
        'photos': [f'IMG_{n}.jpg' for n in (3011, 3012, 3027, 3033, 3058, 3074)],
        'documents': ['Budget 2026.xlsx', 'Lease.pdf', 'Trip.md', 'Notes 0925.docx'],
        'work': ['Q3.key', 'Roadmap.pdf', 'Designs/Home.png', 'Designs/Icon.png'],
        'music': ['Run.m3u', 'Guitar.m4a'],
    }
for key, items in files.items():
    folder = names[key]
    os.makedirs(os.path.join(cloud, folder), exist_ok=True)
    for i, name in enumerate(items):
        path = os.path.join(docs, folder, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if name.endswith(('.jpg', '.png')):
            photo(path, (i * 47 + 200) % 360)
        else:
            text(path, f'{name}\n' + 'Velock Sync demo content.\n' * random.randint(20, 400))
photo(os.path.join(cloud, names['photos'], names['server_photo'] + '.jpg'), 30)
print('demo files ready')
