# GRUB Theme

Cyberpunk neon theme for the GRUB bootloader.

## Theme Generation Pipeline

The theme is generated from a template using the standard apply-themes workflow:

```
Template: ~/dev/custom/themes/base16-cyberpunk/templates/grub-theme.txt.ejs
Scheme:   ~/dev/custom/themes/base16-cyberpunk/scheme/cyberpunk.yaml
Output:   ~/dev/custom/hypr/themes/grub/theme.txt
```

Generate with:
```bash
~/dev/custom/scripts/apply-themes
```

## Installation Process

GRUB theme installation requires root privileges and modifies system files. Per the project rules in ~/CLAUDE.md, provide instructions for the user to execute rather than running these commands directly.

### Step 1: Generate PNG Assets

Requires `media-gfx/imagemagick`:
```bash
~/dev/custom/hypr/themes/grub/generate-assets.sh
```

### Step 2: Convert Fonts

GRUB requires PF2 format fonts:
```bash
sudo mkdir -p /boot/grub/fonts
sudo grub-mkfont -o /boot/grub/fonts/inconsolata_regular_12.pf2 -s 12 /usr/share/fonts/inconsolata/Inconsolata-Regular.ttf
sudo grub-mkfont -o /boot/grub/fonts/inconsolata_regular_14.pf2 -s 14 /usr/share/fonts/inconsolata/Inconsolata-Regular.ttf
sudo grub-mkfont -o /boot/grub/fonts/inconsolata_regular_16.pf2 -s 16 /usr/share/fonts/inconsolata/Inconsolata-Regular.ttf
sudo grub-mkfont -o /boot/grub/fonts/inconsolata_regular_18.pf2 -s 18 /usr/share/fonts/inconsolata/Inconsolata-Regular.ttf
sudo grub-mkfont -o /boot/grub/fonts/inconsolata_bold_18.pf2 -s 18 /usr/share/fonts/inconsolata/Inconsolata-Bold.ttf
sudo grub-mkfont -o /boot/grub/fonts/inconsolata_bold_24.pf2 -s 24 /usr/share/fonts/inconsolata/Inconsolata-Bold.ttf
```

### Step 3: Install Theme

```bash
sudo cp -r ~/dev/custom/hypr/themes/grub /boot/grub/themes/cyberpunk
```

### Step 4: Configure GRUB

Edit `/etc/default/grub`:
```
GRUB_THEME="/boot/grub/themes/cyberpunk/theme.txt"
GRUB_GFXMODE="1920x1080,auto"
GRUB_GFXPAYLOAD_LINUX="keep"
```

### Step 5: Regenerate Config

```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

## File Structure

```
grub/
├── theme.txt           # Generated from template (apply-themes)
├── generate-assets.sh  # ImageMagick script for PNG assets
├── README.md           # User documentation
├── CLAUDE.md           # This file
├── icons/              # Boot entry icons (32x32 PNG)
├── menu_*.png          # Menu container 9-slice
├── select_*.png        # Selection highlight 9-slice
├── scrollbar_*.png     # Scrollbar assets
├── progress_*.png      # Progress bar assets
└── terminal_box_*.png  # Edit mode background
```

## Color Mappings

From cyberpunk.yaml scheme:

| Role | Base | Color | Hex |
|------|------|-------|-----|
| Background | base00 | Deep Dark | #0a0e27 |
| Containers | base01 | Dark Purple | #1a1b3d |
| Selection bg | base02 | Lighter Purple | #252847 |
| Muted text | base03 | Medium Purple | #5a5b7d |
| Primary text | base05 | Soft White | #e0e0ff |
| Selection | base0A | Neon Orange | #ff6b35 |
| Borders | base0B | Electric Blue | #599cff |
| Title/accent | base0D | Neon Cyan | #00f3ff |

## Notes

- The 9-slice PNG system (`*_c.png`, `*_n.png`, etc.) allows GRUB to tile/stretch assets
- Font names in theme.txt must match the installed PF2 font files exactly
- Test changes by rebooting; GRUB doesn't hot-reload
- If theme fails to load, GRUB falls back to text mode (safe)
