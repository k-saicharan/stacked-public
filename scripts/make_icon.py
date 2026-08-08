from PIL import Image, ImageDraw

SIZE = 1024
BG = (15, 15, 26, 255)        # #0F0F1A : matches scaffoldBackgroundColor
ACCENT = (79, 195, 247, 255)  # #4FC3F7 : matches primary color
ACCENT_FACE = (40, 70, 92, 255)   # crate face fill, sits between bg and accent
FOOT = (79, 195, 247, 255)

def rounded_bg(draw, size, color, radius_ratio=0.22):
    r = int(size * radius_ratio)
    draw.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=color)

def crate(draw, x0, y0, x1, y1, frame_w):
    # Outer frame in accent, inner face dimmer: reads as a crate, not a solid bar.
    draw.rounded_rectangle([x0, y0, x1, y1], radius=frame_w * 2, fill=ACCENT)
    draw.rounded_rectangle(
        [x0 + frame_w, y0 + frame_w, x1 - frame_w, y1 - frame_w],
        radius=frame_w, fill=ACCENT_FACE,
    )
    # Slat lines across the face.
    n = 3
    inner_h = (y1 - frame_w) - (y0 + frame_w)
    for i in range(1, n):
        y = y0 + frame_w + inner_h * i // n
        draw.line([x0 + frame_w * 2, y, x1 - frame_w * 2, y], fill=ACCENT, width=max(2, frame_w // 3))

def build(path, foreground_only=False):
    img = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    if not foreground_only:
        rounded_bg(draw, SIZE, BG)

    cx = SIZE // 2
    box_w = int(SIZE * 0.52)
    box_h = int(SIZE * 0.18)
    gap = int(SIZE * 0.035)
    frame_w = int(SIZE * 0.022)

    x0, x1 = cx - box_w // 2, cx + box_w // 2
    top_y0 = int(SIZE * 0.27)
    top_y1 = top_y0 + box_h
    bot_y0 = top_y1 + gap
    bot_y1 = bot_y0 + box_h

    crate(draw, x0, top_y0, x1, top_y1, frame_w)
    crate(draw, x0, bot_y0, x1, bot_y1, frame_w)

    # Skids/feet beneath the stack.
    foot_y0 = bot_y1 + int(SIZE * 0.06)
    foot_h = int(SIZE * 0.045)
    foot_w = int(box_w * 0.22)
    foot_gap = (box_w - foot_w * 3) // 2
    for i in range(3):
        fx0 = x0 + i * (foot_w + foot_gap)
        draw.rounded_rectangle([fx0, foot_y0, fx0 + foot_w, foot_y0 + foot_h],
                                radius=foot_h // 2, fill=FOOT)

    img.save(path)

build('/tmp/tracker_icon_1024.png')
build('/tmp/tracker_icon_fg_1024.png', foreground_only=True)
print('done')
