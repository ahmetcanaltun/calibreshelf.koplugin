std = "luajit"
unused_args = false
self = false
max_line_length = false
globals = { "G_reader_settings", "G_defaults" }
read_globals = { "DGENERIC_ICON_SIZE" }
exclude_files = { "docs/**", "tests/.rocks/**", "tests/emulator/cache/**" }
-- "_" is gettext; never use it as a throwaway variable (it shadows _()).
ignore = { "212/_.*", "213/_.*" }
