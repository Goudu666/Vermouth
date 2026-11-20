#!/usr/bin/env python3
"""生成 Vermouth 应用图标（AppIcon.icns + 1024px PNG）。

设计：Big Sur 风格圆角方形底板，酒红 → 深莓渐变；中央是一只线条马天尼杯，杯中琥珀色味美思，
杯沿挂一片橙皮卷。只依赖 Pillow，可在 Linux / macOS 上重复生成：

    python3 Scripts/make-app-icon.py            # 输出到 Branding/
"""
import io
import math
import struct
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "Branding"
S = 4  # supersampling factor
N = 1024 * S


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def vertical_gradient(size, top, bottom):
    w, h = size
    grad = Image.new("RGBA", (1, h))
    for y in range(h):
        grad.putpixel((0, y), lerp(top, bottom, y / (h - 1)))
    return grad.resize((w, h))


def rounded_mask(size, box, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def build_icon():
    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    # --- Plate: macOS icon grid (824px plate inside 1024 canvas) with soft drop shadow
    margin = 100 * S
    plate_box = (margin, margin, N - margin, N - margin)
    radius = int(185 * S)
    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (plate_box[0], plate_box[1] + 18 * S, plate_box[2], plate_box[3] + 18 * S), radius=radius, fill=(20, 0, 8, 140)
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(28 * S))
    canvas.alpha_composite(shadow)

    plate = vertical_gradient((N, N), (122, 24, 52, 255), (44, 6, 22, 255))
    # warm glow behind the glass
    glow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((N * 0.22, N * 0.18, N * 0.78, N * 0.70), fill=(255, 150, 70, 90))
    glow = glow.filter(ImageFilter.GaussianBlur(90 * S))
    plate.alpha_composite(glow)
    plate_mask = rounded_mask((N, N), plate_box, radius)
    canvas.paste(plate, (0, 0), plate_mask)

    # subtle top sheen
    sheen = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(sheen).rounded_rectangle(plate_box, radius=radius, outline=(255, 255, 255, 46), width=5 * S)
    canvas.alpha_composite(sheen)

    draw = ImageDraw.Draw(canvas)
    cx = N / 2
    rim_y = 300 * S
    rim_half = 250 * S
    apex_y = 600 * S

    # --- Liquid (amber gradient) clipped to the lower part of the cone
    liquid_top = 380 * S
    t = (liquid_top - rim_y) / (apex_y - rim_y)
    half_at_top = rim_half * (1 - t)
    liquid_mask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(liquid_mask).polygon(
        [(cx - half_at_top, liquid_top), (cx + half_at_top, liquid_top), (cx, apex_y - 6 * S)], fill=255
    )
    liquid = vertical_gradient((N, N), (255, 196, 92, 255), (214, 92, 28, 255))
    canvas.paste(liquid, (0, 0), liquid_mask)
    # liquid surface ellipse highlight
    draw.ellipse(
        (cx - half_at_top, liquid_top - 14 * S, cx + half_at_top, liquid_top + 14 * S), fill=(255, 222, 150, 255)
    )

    # --- "Windows" pane reflection inside the liquid: a subtle 2x2 window grid (Windows apps, poured on a Mac)
    pane = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    pdraw = ImageDraw.Draw(pane)
    gx, gy, gs = cx - 52 * S, 425 * S, 104 * S
    pdraw.rounded_rectangle((gx, gy, gx + gs, gy + gs), radius=10 * S, outline=(255, 236, 190, 120), width=7 * S)
    pdraw.line([(gx + gs / 2, gy), (gx + gs / 2, gy + gs)], fill=(255, 236, 190, 120), width=7 * S)
    pdraw.line([(gx, gy + gs / 2), (gx + gs, gy + gs / 2)], fill=(255, 236, 190, 120), width=7 * S)
    pane_clip = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    pane_clip.paste(pane, (0, 0), liquid_mask)
    canvas.alpha_composite(pane_clip)

    # --- Citrus wheel on the rim (behind the rim line)
    ox, oy, orad = cx + rim_half - 18 * S, rim_y - 34 * S, 74 * S
    draw.ellipse((ox - orad, oy - orad, ox + orad, oy + orad), fill=(244, 120, 28, 255))
    inner = orad - 13 * S
    draw.ellipse((ox - inner, oy - inner, ox + inner, oy + inner), fill=(255, 196, 96, 255))
    for k in range(8):
        ang = k * math.pi / 4
        draw.line([(ox, oy), (ox + math.cos(ang) * inner, oy + math.sin(ang) * inner)], fill=(244, 150, 52, 255), width=6 * S)
    draw.ellipse((ox - 9 * S, oy - 9 * S, ox + 9 * S, oy + 9 * S), fill=(255, 226, 170, 255))

    # --- Glass outline (cone, stem, foot) in warm white
    line = (255, 244, 232, 255)
    w = 22 * S
    draw.line([(cx - rim_half, rim_y), (cx, apex_y), (cx + rim_half, rim_y)], fill=line, width=w, joint="curve")
    draw.ellipse((cx - rim_half - w / 2, rim_y - w / 2, cx - rim_half + w / 2, rim_y + w / 2), fill=line)
    draw.ellipse((cx + rim_half - w / 2, rim_y - w / 2, cx + rim_half + w / 2, rim_y + w / 2), fill=line)
    draw.line([(cx - rim_half, rim_y), (cx + rim_half, rim_y)], fill=line, width=int(w * 0.75))
    stem_bottom = 820 * S
    draw.line([(cx, apex_y), (cx, stem_bottom)], fill=line, width=w)
    foot_half = 150 * S
    draw.rounded_rectangle(
        (cx - foot_half, stem_bottom - w / 2, cx + foot_half, stem_bottom + w * 0.9), radius=w, fill=line
    )

    # --- Glass highlight
    hl = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(hl).line(
        [(cx - rim_half + 70 * S, rim_y + 40 * S), (cx - 70 * S, apex_y - 120 * S)], fill=(255, 255, 255, 110), width=10 * S
    )
    canvas.alpha_composite(hl.filter(ImageFilter.GaussianBlur(2 * S)))

    # Clip everything to the plate (plus shadow outside)
    clipped = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    clipped.alpha_composite(shadow)
    inner = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    inner.paste(canvas, (0, 0), plate_mask)
    clipped.alpha_composite(inner)
    return clipped.resize((1024, 1024), Image.LANCZOS)


def png_bytes(img, px):
    buf = io.BytesIO()
    img.resize((px, px), Image.LANCZOS).save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def write_icns(img, path):
    # PNG-backed icns chunk types supported by macOS 10.7+
    chunks = [("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64), ("ic07", 128),
              ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024)]
    body = b""
    for ostype, px in chunks:
        data = png_bytes(img, px)
        body += ostype.encode("ascii") + struct.pack(">I", len(data) + 8) + data
    path.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


def main():
    OUT_DIR.mkdir(exist_ok=True)
    icon = build_icon()
    icon.save(OUT_DIR / "AppIcon-1024.png", optimize=True)
    write_icns(icon, OUT_DIR / "AppIcon.icns")
    print(f"wrote {OUT_DIR / 'AppIcon.icns'} and AppIcon-1024.png")


if __name__ == "__main__":
    sys.exit(main())
