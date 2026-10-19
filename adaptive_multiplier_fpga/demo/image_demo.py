#!/usr/bin/env python3
"""
image_demo.py -- application-level demo for Review 2.

Runs a 3x3 Gaussian blur where EVERY pixel x weight product goes through a
bit-accurate model of rtl/approx_mult.v (column truncation below `width`
+ 2^(width-1) bias compensation, N = 8). Output is compared against the same
filter computed with exact multiplies (width = 0), using PSNR and SSIM.

Three test images with different operand statistics are used, so the same
truncation width gives different quality on each -- the effect the mode-11
supervisor's drift estimator is meant to track at runtime.

Usage:  python3 image_demo.py [--out results_demo]
Needs:  numpy, matplotlib, scikit-image
"""
import argparse, csv, os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from skimage import data, color, img_as_ubyte
from skimage.metrics import peak_signal_noise_ratio as psnr
from skimage.metrics import structural_similarity as ssim

N = 8

def approx_mult(a, b, width):
    """Vectorised, bit-accurate copy of approx_mult.v / golden_model.py."""
    a = a.astype(np.int64); b = b.astype(np.int64)
    total = np.zeros(np.broadcast(a, b).shape, dtype=np.int64)
    mask = ~((1 << width) - 1) if width > 0 else -1
    for i in range(N):
        row = np.where((b >> i) & 1, a << i, 0)
        total += row & mask
    if width > 0:
        total += 1 << (width - 1)
    return total

# 3x3 Gaussian (sigma = 1) quantised to 8-bit weights that sum to 256
KERNEL = np.array([[19, 31, 19],
                   [31, 56, 31],
                   [19, 31, 19]], dtype=np.int64)
assert KERNEL.sum() == 256

def blur(img, width):
    h, w = img.shape
    pad = np.pad(img, 1, mode="edge").astype(np.int64)
    acc = np.zeros((h, w), dtype=np.int64)
    for dy in range(3):
        for dx in range(3):
            acc += approx_mult(pad[dy:dy + h, dx:dx + w], KERNEL[dy, dx], width)
    return np.clip(acc >> 8, 0, 255).astype(np.uint8)

def load_images():
    imgs = {
        "cameraman (mid-tone)": data.camera(),
        "moon (dark)":          data.moon(),
        "coins (bright)":       img_as_ubyte(np.clip(data.coins() / 255.0 * 0.45 + 0.55, 0, 1)),
    }
    return {k: v.astype(np.uint8) for k, v in imgs.items()}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="results_demo")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    imgs = load_images()
    widths = list(range(0, 13))
    rows = []
    for name, img in imgs.items():
        ref = blur(img, 0)
        for w in widths:
            out = blur(img, w)
            p = float("inf") if w == 0 else psnr(ref, out, data_range=255)
            s = ssim(ref, out, data_range=255)
            rows.append((name, w, p, s, float(img.mean())))
            print(f"{name:22s} width={w:2d}  PSNR={p:6.2f} dB  SSIM={s:.4f}")
    with open(os.path.join(args.out, "image_psnr_ssim.csv"), "w", newline="") as f:
        wr = csv.writer(f); wr.writerow(["image", "width", "psnr_db", "ssim", "mean_pixel"])
        wr.writerows(rows)

    # Largest width that keeps PSNR >= 35 dB, per image
    print("\nLargest width with PSNR >= 35 dB:")
    for name in imgs:
        ok = [w for (n, w, p, s, m) in rows if n == name and p >= 35]
        print(f"  {name:22s} -> width {max(ok)}")

    # Figure: original | width 8 | width 10 per image
    fig, ax = plt.subplots(len(imgs), 3, figsize=(9, 3 * len(imgs)))
    for r, (name, img) in enumerate(imgs.items()):
        ref = blur(img, 0)
        for c, w in enumerate([0, 8, 10]):
            out = ref if w == 0 else blur(img, w)
            ax[r, c].imshow(out, cmap="gray", vmin=0, vmax=255)
            t = "exact (mode 00)" if w == 0 else f"width {w}: {psnr(ref, out, data_range=255):.1f} dB"
            ax[r, c].set_title(f"{name}\n{t}", fontsize=9)
            ax[r, c].axis("off")
    fig.tight_layout()
    fig.savefig(os.path.join(args.out, "image_demo_grid.png"), dpi=130)
    print(f"\nWrote {args.out}/image_psnr_ssim.csv and {args.out}/image_demo_grid.png")

if __name__ == "__main__":
    main()
