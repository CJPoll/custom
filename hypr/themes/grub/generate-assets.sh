#!/bin/bash
# Generate GRUB theme assets using ImageMagick
# Run this script after installing media-gfx/imagemagick

set -e
cd "$(dirname "$0")"

# Colors from cyberpunk scheme
DEEP_DARK="#0a0e27"
DARK_PURPLE="#1a1b3d"
LIGHTER_PURPLE="#252847"
MEDIUM_PURPLE="#5a5b7d"
NEON_CYAN="#00f3ff"
NEON_ORANGE="#ff6b35"
ELECTRIC_BLUE="#599cff"
SOFT_WHITE="#e0e0ff"

echo "Generating GRUB theme assets..."

# Menu 9-slice (dark purple container with electric blue border)
echo "  Creating menu assets..."
magick -size 4x4 xc:"$DARK_PURPLE" menu_c.png
magick -size 4x2 xc:"$ELECTRIC_BLUE" menu_n.png
magick -size 4x2 xc:"$ELECTRIC_BLUE" menu_s.png
magick -size 2x4 xc:"$ELECTRIC_BLUE" menu_e.png
magick -size 2x4 xc:"$ELECTRIC_BLUE" menu_w.png
magick -size 2x2 xc:"$ELECTRIC_BLUE" menu_nw.png
magick -size 2x2 xc:"$ELECTRIC_BLUE" menu_ne.png
magick -size 2x2 xc:"$ELECTRIC_BLUE" menu_sw.png
magick -size 2x2 xc:"$ELECTRIC_BLUE" menu_se.png

# Selection 9-slice (gradient with orange border for selected item)
echo "  Creating selection assets..."
magick -size 4x4 -define gradient:direction=south \
  gradient:"$LIGHTER_PURPLE-$DARK_PURPLE" select_c.png
magick -size 4x2 xc:"$NEON_ORANGE" select_n.png
magick -size 4x2 xc:"$NEON_ORANGE" select_s.png
magick -size 2x4 xc:"$NEON_ORANGE" select_e.png
magick -size 2x4 xc:"$NEON_ORANGE" select_w.png
magick -size 2x2 xc:"$NEON_ORANGE" select_nw.png
magick -size 2x2 xc:"$NEON_ORANGE" select_ne.png
magick -size 2x2 xc:"$NEON_ORANGE" select_sw.png
magick -size 2x2 xc:"$NEON_ORANGE" select_se.png

# Scrollbar
echo "  Creating scrollbar assets..."
magick -size 4x4 xc:"$NEON_CYAN" scrollbar_thumb_c.png
magick -size 2x2 xc:"$NEON_CYAN" scrollbar_thumb_n.png
magick -size 2x2 xc:"$NEON_CYAN" scrollbar_thumb_s.png
magick -size 2x4 xc:"$NEON_CYAN" scrollbar_thumb_e.png
magick -size 2x4 xc:"$NEON_CYAN" scrollbar_thumb_w.png
magick -size 2x2 xc:"$NEON_CYAN" scrollbar_thumb_nw.png
magick -size 2x2 xc:"$NEON_CYAN" scrollbar_thumb_ne.png
magick -size 2x2 xc:"$NEON_CYAN" scrollbar_thumb_sw.png
magick -size 2x2 xc:"$NEON_CYAN" scrollbar_thumb_se.png

magick -size 4x4 xc:"$DARK_PURPLE" scrollbar_frame_c.png
magick -size 2x2 xc:"$DARK_PURPLE" scrollbar_frame_n.png
magick -size 2x2 xc:"$DARK_PURPLE" scrollbar_frame_s.png
magick -size 2x4 xc:"$DARK_PURPLE" scrollbar_frame_e.png
magick -size 2x4 xc:"$DARK_PURPLE" scrollbar_frame_w.png
magick -size 2x2 xc:"$DARK_PURPLE" scrollbar_frame_nw.png
magick -size 2x2 xc:"$DARK_PURPLE" scrollbar_frame_ne.png
magick -size 2x2 xc:"$DARK_PURPLE" scrollbar_frame_sw.png
magick -size 2x2 xc:"$DARK_PURPLE" scrollbar_frame_se.png

# Progress bar
echo "  Creating progress bar assets..."
magick -size 4x4 xc:"$DARK_PURPLE" progress_bar_c.png
magick -size 2x2 xc:"$ELECTRIC_BLUE" progress_bar_n.png
magick -size 2x2 xc:"$ELECTRIC_BLUE" progress_bar_s.png
magick -size 2x4 xc:"$ELECTRIC_BLUE" progress_bar_e.png
magick -size 2x4 xc:"$ELECTRIC_BLUE" progress_bar_w.png
magick -size 2x2 xc:"$ELECTRIC_BLUE" progress_bar_nw.png
magick -size 2x2 xc:"$ELECTRIC_BLUE" progress_bar_ne.png
magick -size 2x2 xc:"$ELECTRIC_BLUE" progress_bar_sw.png
magick -size 2x2 xc:"$ELECTRIC_BLUE" progress_bar_se.png

magick -size 4x4 xc:"$NEON_CYAN" progress_highlight_c.png
magick -size 2x2 xc:"$NEON_CYAN" progress_highlight_n.png
magick -size 2x2 xc:"$NEON_CYAN" progress_highlight_s.png
magick -size 2x4 xc:"$NEON_CYAN" progress_highlight_e.png
magick -size 2x4 xc:"$NEON_CYAN" progress_highlight_w.png
magick -size 2x2 xc:"$NEON_CYAN" progress_highlight_nw.png
magick -size 2x2 xc:"$NEON_CYAN" progress_highlight_ne.png
magick -size 2x2 xc:"$NEON_CYAN" progress_highlight_sw.png
magick -size 2x2 xc:"$NEON_CYAN" progress_highlight_se.png

# Terminal box (for edit mode)
echo "  Creating terminal box assets..."
magick -size 4x4 xc:"$DEEP_DARK" terminal_box_c.png
magick -size 4x2 xc:"$NEON_CYAN" terminal_box_n.png
magick -size 4x2 xc:"$NEON_CYAN" terminal_box_s.png
magick -size 2x4 xc:"$NEON_CYAN" terminal_box_e.png
magick -size 2x4 xc:"$NEON_CYAN" terminal_box_w.png
magick -size 2x2 xc:"$NEON_CYAN" terminal_box_nw.png
magick -size 2x2 xc:"$NEON_CYAN" terminal_box_ne.png
magick -size 2x2 xc:"$NEON_CYAN" terminal_box_sw.png
magick -size 2x2 xc:"$NEON_CYAN" terminal_box_se.png

echo "Done! Assets generated in $(pwd)"
echo ""
echo "Next steps:"
echo "  1. Install fonts: see README.md for grub-mkfont commands"
echo "  2. Copy theme: sudo cp -r . /boot/grub/themes/cyberpunk"
echo "  3. Edit /etc/default/grub to set GRUB_THEME"
echo "  4. Run: sudo grub-mkconfig -o /boot/grub/grub.cfg"
