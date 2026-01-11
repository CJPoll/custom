# Cyberpunk Neon GRUB Theme

A GRUB bootloader theme matching the Hyprland desktop cyberpunk aesthetic.

## Required Assets

GRUB themes require PNG image assets. Generate these using ImageMagick or GIMP:

### Menu Background (menu_*.png)
9-slice images for the boot menu container:
- `menu_c.png` - Center fill (Dark Purple #1a1b3d with subtle gradient)
- `menu_n.png`, `menu_s.png` - Top/bottom edges
- `menu_e.png`, `menu_w.png` - Left/right edges
- `menu_ne.png`, `menu_nw.png`, `menu_se.png`, `menu_sw.png` - Corners

### Selection Highlight (select_*.png)
9-slice images for selected menu item (Neon Orange #ff6b35 border with glow):
- `select_c.png` - Center (gradient from #1a1b3d to #252847)
- `select_n.png`, `select_s.png`, etc. - Edges with orange glow

### Scrollbar
- `scrollbar_thumb_*.png` - Cyan (#00f3ff) scrollbar handle
- `scrollbar_frame_*.png` - Dark purple (#1a1b3d) track

### Progress Bar
- `progress_bar_*.png` - Background track
- `progress_highlight_*.png` - Cyan fill

### Terminal Box
- `terminal_box_*.png` - Terminal/edit mode background

### Icons (optional, in icons/)
32x32 PNG icons for boot entries:
- `gentoo.png` - Gentoo logo
- `linux.png` - Generic Linux
- `windows.png` - Windows
- `unknown.png` - Fallback

## Quick Asset Generation

Generate basic assets with ImageMagick:

```bash
cd ~/dev/custom/hypr/themes/grub

# Menu center (dark purple)
magick -size 64x64 xc:'#1a1b3d' menu_c.png

# Selection center (gradient)
magick -size 64x64 gradient:'#252847-#1a1b3d' select_c.png

# Selection with orange border (simple version)
magick -size 64x64 xc:'#1a1b3d' -strokewidth 2 -stroke '#ff6b35' \
  -draw "rectangle 1,1 62,62" select_c.png

# Scrollbar thumb
magick -size 8x32 xc:'#00f3ff' scrollbar_thumb_c.png

# Scrollbar frame
magick -size 8x32 xc:'#1a1b3d' scrollbar_frame_c.png

# Progress bar background
magick -size 32x8 xc:'#1a1b3d' progress_bar_c.png

# Progress highlight
magick -size 32x8 xc:'#00f3ff' progress_highlight_c.png

# Terminal box
magick -size 64x64 xc:'#0a0e27' terminal_box_c.png
```

For a polished look with glows and proper 9-slice corners, use GIMP or a dedicated theme generator.

## Font Installation

GRUB needs fonts in PF2 format:

```bash
# Create fonts directory and convert Inconsolata for GRUB
sudo mkdir -p /boot/grub/fonts
sudo grub-mkfont -o /boot/grub/fonts/inconsolata_regular_16.pf2 -s 16 \
  /usr/share/fonts/inconsolata/Inconsolata-Regular.ttf

sudo grub-mkfont -o /boot/grub/fonts/inconsolata_regular_18.pf2 -s 18 \
  /usr/share/fonts/inconsolata/Inconsolata-Regular.ttf

sudo grub-mkfont -o /boot/grub/fonts/inconsolata_bold_18.pf2 -s 18 \
  /usr/share/fonts/inconsolata/Inconsolata-Bold.ttf

sudo grub-mkfont -o /boot/grub/fonts/inconsolata_bold_24.pf2 -s 24 \
  /usr/share/fonts/inconsolata/Inconsolata-Bold.ttf

sudo grub-mkfont -o /boot/grub/fonts/inconsolata_regular_12.pf2 -s 12 \
  /usr/share/fonts/inconsolata/Inconsolata-Regular.ttf

sudo grub-mkfont -o /boot/grub/fonts/inconsolata_regular_14.pf2 -s 14 \
  /usr/share/fonts/inconsolata/Inconsolata-Regular.ttf
```

## Installation

1. Copy theme to GRUB themes directory:
   ```bash
   sudo cp -r ~/dev/custom/hypr/themes/grub /boot/grub/themes/cyberpunk
   ```

2. Edit `/etc/default/grub`:
   ```bash
   GRUB_THEME="/boot/grub/themes/cyberpunk/theme.txt"
   GRUB_GFXMODE="1920x1080,auto"
   GRUB_GFXPAYLOAD_LINUX="keep"
   ```

3. Regenerate GRUB config:
   ```bash
   sudo grub-mkconfig -o /boot/grub/grub.cfg
   ```

## Color Reference

| Name | Hex | Usage |
|------|-----|-------|
| Deep Dark | #0a0e27 | Background |
| Dark Purple | #1a1b3d | Containers, menu background |
| Lighter Purple | #252847 | Selection gradient |
| Medium Purple | #5a5b7d | Muted text (timeout, help) |
| Soft White | #e0e0ff | Primary text |
| Neon Cyan | #00f3ff | Title, progress bar |
| Neon Orange | #ff6b35 | Selection highlight |
| Electric Blue | #599cff | Borders |
