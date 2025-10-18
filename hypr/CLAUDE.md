# Hyprland Desktop Environment Configuration

## Design Philosophy

### Visual Style: Neon Cyberpunk
The desktop environment embraces a cyberpunk aesthetic with neon accents, dark backgrounds, and glowing effects. The design draws inspiration from futuristic cityscapes with heavy use of purples, pinks, and cyan accents.

### Spacing and Layout
- **Generous padding**: UI elements prioritize breathing space and comfortable spacing
- **Clean and minimal**: Avoid clutter; show only what's necessary
- **Consistent margins**: All modules maintain uniform spacing (typically 4px-24px depending on context)

### Typography
- **Primary font**: Inconsolata for Powerline
- **Fallback**: Inconsolata, JetBrains Mono, Fira Code
- **Style**: Monospace for consistency and technical aesthetic
- **Sizes**: 14-18px base, with specific modules using larger sizes for emphasis
- **Powerline support**: Includes special glyphs for status lines and prompts

## Color Palette

### Primary Colors

| Color Name | Hex Code | Usage | RGB |
|------------|----------|-------|-----|
| Deep Dark | `#0a0e27` | Main backgrounds, base layer | rgba(10, 14, 39) |
| Dark Purple | `#1a1b3d` | Container backgrounds, module backgrounds | rgba(26, 27, 61) |
| Neon Red | `#ff0066` | Errors, deletions, warnings | rgba(255, 0, 102) |
| Neon Green | `#39ff14` | Success, additions, confirmations | rgba(57, 255, 20) |
| Neon Cyan | `#00f3ff` | Primary accent, active states, primary borders | rgba(0, 243, 255) |
| Neon Magenta | `#ff00ff` | Secondary accent, important elements | rgba(255, 0, 255) |
| Electric Blue | `#0066ff` | Highlights, secondary borders | rgba(0, 102, 255) |
| Neon Orange | `#ff6b35` | Hover emphasis, attention-grabbing, lock screen theme | rgba(255, 107, 53) |
| Soft White | `#e0e0ff` | Primary text color | rgba(224, 224, 255) |

### Color Usage Guidelines

**Background Hierarchy:**
1. Deep Dark (#0a0e27) - Window backgrounds, outer containers
2. Dark Purple (#1a1b3d) - Module containers, input fields
3. Lighter variants (rgba with adjusted alpha) - Hover states

**Accent Colors:**
- **Red (#ff0066)**: Errors, deletions, critical warnings, urgent states
- **Green (#39ff14)**: Success messages, additions, confirmations, completed states
- **Cyan (#00f3ff)**: Primary brand color, active workspaces, clock, memory stats, important borders
- **Magenta (#ff00ff)**: CPU stats, audio controls, lock icon, secondary highlights
- **Orange (#ff6b35)**: Hover states, attention required, warnings, lock screen emphasis
- **Blue (#0066ff)**: Information, directories, secondary elements

**Text Colors:**
- **Soft White (#e0e0ff)**: Default text
- **Cyan (#00f3ff)**: Active/selected text with glow effects
- **Orange (#ff6b35)**: Hover text with glow effects

### Visual Effects

**Glows and Shadows:**
- Use `text-shadow` and `box-shadow` with matching color at ~0.3-0.8 alpha
- Hover states increase glow intensity (8px → 12-15px)
- Active states use dual shadows (outer glow + inner glow)

**Animations:**
- Duration: 0.2-0.3s for standard transitions
- Easing: `ease` for smooth, natural motion
- Pulse animations: 1-2s duration for attention states

**Borders:**
- Standard: 1-2px solid with rgba colors
- Active states use brighter, more opaque colors
- Border radius: 6-12px depending on element size

## Theme Files and Integration

### Theme File Locations
All theme files are stored in `~/dev/custom/hypr/themes/`:
- `base16-cyberpunk.vim` - Vim/Neovim color scheme
- `base16-cyberpunk.sh` - Shell/terminal theme (sourced by ZSH)
- `base16-cyberpunk.yaml` - Theme definition/specification
- `alacritty-cyberpunk.toml` - Alacritty terminal color theme

### System Integration via Symlinks
The Vim color scheme is integrated via symlink:
```bash
~/.vim/colors/base16-cyberpunk.vim -> ~/dev/custom/hypr/themes/base16-cyberpunk.vim
```

This allows Vim/Neovim to find the color scheme without modifying the runtimepath. If the theme files are moved, update the symlink:
```bash
ln -sf ~/dev/custom/hypr/themes/base16-cyberpunk.vim ~/.vim/colors/base16-cyberpunk.vim
```

### Theme Loading
- **Vim/Neovim**: `colorscheme base16-cyberpunk` in `init.vim`
- **ZSH**: Sourced in `~/.zshrc.theme-override` via `source "${HOME}/dev/custom/hypr/themes/base16-cyberpunk.sh"`
- **Alacritty**: Imported in `~/dev/custom/hypr/alacritty.toml` via `import` directive

## Wallpapers

| Screen | Image | Theme |
|--------|-------|-------|
| Main Display | `~/Pictures/cyberpunk-main.jpg` | Blue/cyan cityscape with silhouette |
| Secondary Display (Rotated) | `~/Pictures/cyberpunk-rotated.jpg` | Rotated variant |
| Lock Screen | `~/Pictures/cyberpunk-lock.jpg` | Orange-dominant futuristic cityscape |

The lock screen wallpaper specifically leans into the neon orange color, which is reflected in hyprlock's UI design.

## Component Styling Patterns

### Modules (Waybar)
- Background: Dark Purple with transparency (rgba(26, 27, 61, 0.8))
- Border: Electric Blue with low opacity (rgba(0, 102, 255, 0.3))
- Border radius: 8px
- Padding: 4px 12-16px
- Hover: Orange border with glow effect

### Workspaces
- Inactive: Dark Purple background, Electric Blue border
- Active: Cyan/Magenta gradient background, Cyan border, cyan glow
- Hover: Orange border and text with glow
- Urgent: Red with blinking animation

### Interactive Elements
- Default state: Magenta or Cyan color with subtle glow
- Hover state: Orange color with intensified glow
- Selected state: Cyan with gradient background

### Inputs (Wofi)
- Container: Deep Dark background with Cyan border
- Entry padding: 16-20px for generous spacing
- Selected: Magenta border with gradient background
- Focus: Increased shadow/glow effect

## Development Guidelines

### When Adding New Components
1. Use the established color palette - do not introduce new colors
2. Maintain generous padding (minimum 4px, prefer 12-24px for containers)
3. Add hover states with orange emphasis
4. Include appropriate glow effects (text-shadow and box-shadow)
5. Use consistent border-radius (6-12px range)
6. Ensure smooth transitions (0.2-0.3s)

### CSS Class Naming
Follow component-specific naming:
- Waybar modules: `#module-name`
- States: `.active`, `.passive`, `.needs-attention`, `.urgent`, etc.
- Nested elements: `#parent > .child`

### Consistency Checklist
- [ ] Uses JetBrains Mono font
- [ ] Colors from established palette only
- [ ] Generous padding applied
- [ ] Hover state with orange emphasis
- [ ] Appropriate glow effects
- [ ] Smooth transitions
- [ ] Consistent border radius
- [ ] Matches cyberpunk aesthetic

# OPEN ~/.oh-my-zsh/themes/agnoster.zsh-theme
# Save to ~/.zshrc.theme-override
