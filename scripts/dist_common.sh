#!/bin/zsh
# 共用產物清理：只處理專案根目錄下的 dist。
move_to_trash() {
  local target="$1"
  [[ -e "$target" || -L "$target" ]] || return 0

  local trash_directory="$HOME/.Trash"
  mkdir -p "$trash_directory"
  local base_name="${target:t}"
  local destination="$trash_directory/$base_name"
  local suffix=0
  while [[ -e "$destination" || -L "$destination" ]]; do
    suffix=$((suffix + 1))
    destination="$trash_directory/${base_name}.unifyime-$(date '+%Y%m%d%H%M%S')-$$-$suffix"
  done
  mv -- "$target" "$destination"
  print "已移至 Trash：$target -> $destination"
}

clear_project_dist() {
  local project_directory="${1:A}"
  local dist_directory="$project_directory/dist"
  if [[ -L "$dist_directory" || ( -e "$dist_directory" && ! -d "$dist_directory" ) ]]; then
    print -u2 "dist 必須是實體目錄：$dist_directory"
    return 1
  fi
  mkdir -p "$dist_directory"
  local entry
  for entry in "$dist_directory"/*(DN); do
    move_to_trash "$entry"
  done
  print "已清空：$dist_directory"
}
