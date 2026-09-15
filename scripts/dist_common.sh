#!/bin/zsh
# 徹底清理產物，絕不移入垃圾桶，避免 LaunchServices 重複索引 Ghost App
move_to_trash() {
  local target="$1"
  [[ -e "$target" || -L "$target" ]] || return 0
  rm -rf -- "$target"
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
    rm -rf -- "$entry"
  done
}
