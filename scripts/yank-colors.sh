#!/bin/sh
# Selection / yank-flash colour options, printed as they look in this terminal (run it in
# tmux too). In use: N, the same as nvim's kanagawa (Visual -> YankyYanked/Search):
#   tmux copy mode   ~/.tmux.conf   mode-style, @yank_flash_style  (config/.chezmoitemplates/tmux/default.conf)
#   zsh-vi-mode      ~/.config/zsh/zshrc   ZVM_VI_HIGHLIGHT_BACKGROUND, ZSH_YANK_FLASH_STYLE
# Usage: scripts/yank-colors.sh
# Truecolor escapes: \033[48;2;R;G;Bm = background, \033[38;2;R;G;Bm = foreground.
rgb() { printf '%d;%d;%d' 0x${1%????} 0x$(echo $1 | cut -c3-4) 0x${1#????}; }
paint() { # paint BG FG TEXT  (FG "-" = keep the terminal's text colour)
  if [ "$2" = - ]; then printf '\033[48;2;%sm%s\033[0m' "$(rgb $1)" "$3"
  else printf '\033[48;2;%s;38;2;%sm%s\033[0m' "$(rgb $1)" "$(rgb $2)" "$3"; fi
}
sample='git log --oneline -5'

echo
echo "Selection colours (what you see while selecting):"
printf '  S1  %-34s ' 'nvim Visual #223249 (dark blue)';  paint 223249 - " $sample "; echo
printf '  S2  %-34s ' 'Kanagawa waveBlue2 #2D4F67';       paint 2D4F67 - " $sample "; echo
printf '  S3  %-34s ' 'now: yellow on black';             printf '\033[43;30m %s \033[0m\n' "$sample"
echo
echo "Yank flash colours (shown for 0.15s after y), on dark blue text:"
printf '  F1  %-34s ' 'nvim IncSearch #ff9e3b (orange)';  paint ff9e3b 223249 " $sample "; echo
printf '  F2  %-34s ' 'carpYellow #E6C384 (soft yellow)'; paint E6C384 223249 " $sample "; echo
printf '  F3  %-34s ' 'surimiOrange #FFA066';             paint FFA066 223249 " $sample "; echo
printf '  F4  %-34s ' 'springGreen #98BB6C';              paint 98BB6C 223249 " $sample "; echo
printf '  F5  %-34s ' 'crystalBlue #7E9CD8';              paint 7E9CD8 223249 " $sample "; echo
printf '  F6  %-34s ' 'sakuraPink #D27E99';               paint D27E99 223249 " $sample "; echo
echo
echo "Your nvim exactly (Visual -> YankyYanked/Search), in use:"
printf '  N   #223249 -> #2D4F67 + light text   '; paint 223249 - " $sample "; printf '  ->  '; paint 2D4F67 DCD7BA " $sample "; echo
echo
echo "Pairs (selection -> flash):"
for s in 223249 2D4F67; do
  for f in ff9e3b E6C384 98BB6C; do
    printf '  #%s -> #%s   ' $s $f; paint $s - " $sample "; printf '  ->  '; paint $f 223249 " $sample "; echo
  done
done
echo
