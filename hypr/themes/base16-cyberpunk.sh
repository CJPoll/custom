#!/bin/sh
# base16-shell (https://github.com/chriskempson/base16-shell)
# Base16 Shell template by Chris Kempson (http://chriskempson.com)
# Cyberpunk Neon scheme by cjpoll

color00="0a/0e/27" # Deep Dark - Base 00 - Black
color01="ff/00/66" # Neon Red - Base 08 - Red
color02="00/66/ff" # Electric Blue - Base 0B - Green
color03="39/ff/14" # Neon Green - Base 09 - Yellow
color04="00/f3/ff" # Neon Cyan - Base 0D - Blue
color05="ff/6b/35" # Neon Orange - Base 0A - Magenta
color06="ff/00/ff" # Neon Magenta - Base 0C - Cyan
color07="e0/e0/ff" # Soft White - Base 05 - White
color08="5a/5b/7d" # Medium purple-gray - Base 03 - Bright Black
color09="ff/00/66" # Neon Red - Base 08 - Bright Red
color10="00/66/ff" # Electric Blue - Base 0B - Bright Green
color11="39/ff/14" # Neon Green - Base 09 - Bright Yellow
color12="00/f3/ff" # Neon Cyan - Base 0D - Bright Blue
color13="ff/6b/35" # Neon Orange - Base 0A - Bright Magenta
color14="ff/00/ff" # Neon Magenta - Base 0C - Bright Cyan
color15="f5/f5/ff" # Brightest White - Base 07 - Bright White
color16="39/ff/14" # Neon Green - Base 09
color17="ff/33/99" # Brighter Red - Base 0F
color18="1a/1b/3d" # Dark Purple - Base 01
color19="25/28/47" # Lighter Purple - Base 02
color20="9b/9d/c7" # Muted purple - Base 04
color21="eb/eb/ff" # Brighter White - Base 06
color_foreground="e0/e0/ff" # Base 05
color_background="0a/0e/27" # Base 00

if [ -n "$TMUX" ]; then
  # Tell tmux to pass the escape sequences through
  printf_template='\033Ptmux;\033\033]4;%d;rgb:%s\033\033\\\033\\'
  printf_template_var='\033Ptmux;\033\033]%d;rgb:%s\033\033\\\033\\'
  printf_template_custom='\033Ptmux;\033\033]%s%s\033\033\\\033\\'
elif [ "${TERM%%[-.]*}" = "screen" ]; then
  # GNU screen (screen, screen-256color, screen-256color-bce)
  printf_template='\033P\033]4;%d;rgb:%s\007\033\\'
  printf_template_var='\033P\033]%d;rgb:%s\007\033\\'
  printf_template_custom='\033P\033]%s%s\007\033\\'
elif [ "${TERM%%-*}" = "linux" ]; then
  printf_template='\033]P%x%s'
  printf_template_var='\033]P%x%s'
  printf_template_custom=''
else
  printf_template='\033]4;%d;rgb:%s\033\\'
  printf_template_var='\033]%d;rgb:%s\033\\'
  printf_template_custom='\033]%s%s\033\\'
fi

# 16 color space
printf $printf_template 0  $color00
printf $printf_template 1  $color01
printf $printf_template 2  $color02
printf $printf_template 3  $color03
printf $printf_template 4  $color04
printf $printf_template 5  $color05
printf $printf_template 6  $color06
printf $printf_template 7  $color07
printf $printf_template 8  $color08
printf $printf_template 9  $color09
printf $printf_template 10 $color10
printf $printf_template 11 $color11
printf $printf_template 12 $color12
printf $printf_template 13 $color13
printf $printf_template 14 $color14
printf $printf_template 15 $color15

# 256 color space
printf $printf_template 16 $color16
printf $printf_template 17 $color17
printf $printf_template 18 $color18
printf $printf_template 19 $color19
printf $printf_template 20 $color20
printf $printf_template 21 $color21

# foreground / background / cursor color
if [ -n "$ITERM_SESSION_ID" ]; then
  # iTerm2 proprietary escape codes
  printf $printf_template_custom Pg e0e0ff # foreground
  printf $printf_template_custom Ph 0a0e27 # background
  printf $printf_template_custom Pi e0e0ff # bold color
  printf $printf_template_custom Pj 252847 # selection color
  printf $printf_template_custom Pk e0e0ff # selected text color
  printf $printf_template_custom Pl 00f3ff # cursor
  printf $printf_template_custom Pm 0a0e27 # cursor text
else
  printf $printf_template_var 10 $color_foreground
  if [ "$BASE16_SHELL_SET_BACKGROUND" != false ]; then
    printf $printf_template_var 11 $color_background
    if [ "${TERM%%-*}" = "rxvt" ]; then
      printf $printf_template_var 708 $color_background # internal border (rxvt)
    fi
  fi
  printf $printf_template_custom 12 ";7" # cursor (reverse video)
fi

# clean up
unset printf_template
unset printf_template_var
unset printf_template_custom
unset color00
unset color01
unset color02
unset color03
unset color04
unset color05
unset color06
unset color07
unset color08
unset color09
unset color10
unset color11
unset color12
unset color13
unset color14
unset color15
unset color16
unset color17
unset color18
unset color19
unset color20
unset color21
unset color_foreground
unset color_background
