"""Finder layout for the release DMG. Used by dmgbuild, not by the app."""
import os

app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
format = "UDZO"
filesystem = "HFS+"
volume_name = "Plaintexter"
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")
background = defines["background"]
window_rect = ((180, 180), (640, 360))
icon_locations = {"Plaintexter.app": (160, 160), "Applications": (480, 160)}
icon_size = 112
grid_spacing = 80
text_size = 14
default_view = "icon-view"
show_icon_preview = False
show_toolbar = False
show_status_bar = False
show_sidebar = False
show_tab_view = False
show_pathbar = False
# Hiding a signed bundle's extension adds FinderInfo, which fails strict signature validation.
hide_extensions = []
include_icon_view_settings = True
include_list_view_settings = False
