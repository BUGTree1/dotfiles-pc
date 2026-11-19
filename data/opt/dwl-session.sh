#!/usr/bin/env bash

export XDG_CURRENT_DESKTOP=wlroots
export XDG_SESSION_TYPE=wayland
export MOZ_ENABLE_WAYLAND=1

dbus-update-activation-environment --systemd --all

exec dwl
