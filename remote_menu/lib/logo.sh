#!/bin/bash

THEME_COLORS=(
  '\033[0;31m'
  '\033[0;32m'
  '\033[0;33m'
  '\033[0;34m'
  '\033[0;35m'
  '\033[1;31m'
  '\033[1;32m'
  '\033[1;33m'
  '\033[1;34m'
  '\033[1;35m'
  '\033[1;36m'
)
BOLD='\033[1m'
NC='\033[0m'

print_logo() {
  local color="$1"
  echo -e "${color}${BOLD}"
  cat << 'EOF'
       _____                          __              
      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
             /___/                                    
                                                
EOF
}

play_logo_animation() {
  clear
  tput civis
  for _ in {1..5}; do
    tput cup 0 0
    local anim_color="${THEME_COLORS[$RANDOM % ${#THEME_COLORS[@]}]}"
    print_logo "$anim_color"
    sleep 0.03
  done
  local final_color="${THEME_COLORS[$RANDOM % ${#THEME_COLORS[@]}]}"
  tput cup 0 0
  print_logo "$final_color"
  echo -e "${NC}"
  tput cnorm
}
