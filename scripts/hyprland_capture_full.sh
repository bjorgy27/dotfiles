mkdir -p "$HOME/screenshots"
output=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .name') && time=$(date +"%Y-%m-%d_%H.%M:%S") && grim -o "$output" "$HOME/screenshots/$time.png" && grim -o "$output" - | wl-copy
