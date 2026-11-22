#!/usr/bin/env bash
#
# Rofi script modi: AppImage launcher / extractor.
#
#   rofi -modi "apps:$0" -show apps -show-icons
#
# Without arguments it extracts every new or updated *.AppImage in
# ~/AppImages into ~/AppImages/extracted/<name>/ and prints one rofi entry
# (with icon) per app.  When rofi calls the script back with the selected
# entry as argument(s), it starts the app from the EXTRACTED copy: the
# bundle's AppRun launcher (the same entry point the AppImage runtime
# would exec).  Only if no runnable AppRun exists does it fall back to
# running the packed AppImage itself.

APPDIR="$HOME/AppImages"
EXTRACT_DIR="$APPDIR/extracted"

notify() { # notify <icon> <summary> <body>
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -i "$1" "$2" "$3"
    fi
}

# Read a key from the [Desktop Entry] section of a desktop file.  Only the
# main section is read, so a [Desktop Action]'s Name/Icon can never leak
# through, and values containing '=' survive (index/substr instead of -F=).
desktop_field() { # desktop_field <key> <file>
    awk -v key="$1" '
        /^\[/                { sec = ($0 == "[Desktop Entry]") }
        /^[[:space:]]*#/     { next }
        sec && (i = index($0, "=")) {
            k = substr($0, 1, i - 1)
            v = substr($0, i + 1)
            sub(/\r$/, "", v)
            if (k == key && v != "") { print v; exit }
        }
    ' "$2"
}

# Pick the app's .desktop file deterministically: a stem match first, then
# the standard locations (top level, usr/share/applications,
# usr/local/share/applications), then anywhere in the bundle.
app_desktop_file() { # app_desktop_file <dir> <stem>
    local d=$1 stem=$2 place hit
    for place in "$d" "$d/usr/share/applications" "$d/usr/local/share/applications"; do
        if [ -f "$place/$stem.desktop" ]; then
            printf '%s\n' "$place/$stem.desktop"
            return 0
        fi
        hit=$(find "$place" -maxdepth 1 -name '*.desktop' 2>/dev/null | LC_ALL=C sort | head -n 1)
        if [ -n "$hit" ]; then
            printf '%s\n' "$hit"
            return 0
        fi
    done
    hit=$(find "$d" -type f -name "$stem.desktop" 2>/dev/null | LC_ALL=C sort | head -n 1)
    if [ -n "$hit" ]; then
        printf '%s\n' "$hit"
        return 0
    fi
    find "$d" -type f -name '*.desktop' 2>/dev/null | LC_ALL=C sort | head -n 1
}

# Display name.  ONE implementation used by BOTH phases, so the string rofi
# shows is always exactly the string phase 2 matches against.  Locale-aware:
# Name[lang_COUNTRY] > Name[lang] > Name > first other Name[...] > stem.
app_display_name() { # app_display_name <dir> <stem>
    local f name lang short
    f=$(app_desktop_file "$1" "$2")
    if [ -n "$f" ]; then
        lang=${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}
        lang=${lang%@*}
        lang=${lang%.*}          # en_US.UTF-8@euro -> en_US
        short=${lang%%_*}        # en_US -> en
        name=$(awk -v l1="Name[$lang]" -v l2="Name[$short]" '
            /^\[/                { sec = ($0 == "[Desktop Entry]") }
            /^[[:space:]]*#/     { next }
            sec && (i = index($0, "=")) {
                k = substr($0, 1, i - 1)
                v = substr($0, i + 1)
                sub(/\r$/, "", v)
                if      (k == l1       && p1 == "") p1 = v
                else if (k == l2       && p2 == "") p2 = v
                else if (k == "Name"   && pn == "") pn = v
                else if (k ~ /^Name\[/ && px == "") px = v
            }
            END {
                if      (p1 != "") print p1
                else if (p2 != "") print p2
                else if (pn != "") print pn
                else if (px != "") print px
            }
        ' "$f")
        if [ -n "$name" ]; then
            printf '%s\n' "$name"
            return 0
        fi
    fi
    printf '%s\n' "$2"
}

# Resolve the Icon= value to something rofi can render: an absolute path as
# is, then an image file inside the bundle (png/svg/xpm only -- the old
# "$icon.*" glob could happily match "$icon.desktop"), then the raw name,
# which rofi resolves through the system icon theme on its own.
app_icon() { # app_icon <dir> <Icon= value>
    local d=$1 icon=$2 hit
    [ -n "$icon" ] || return 0
    case $icon in
        /*)
            [ -f "$icon" ] && printf '%s\n' "$icon"
            return 0
            ;;
    esac
    hit=$(find "$d" -type f \( -iname "$icon" -o -iname "$icon.png" \
            -o -iname "$icon.svg" -o -iname "$icon.xpm" \) 2>/dev/null \
          | LC_ALL=C sort | head -n 1)
    if [ -n "$hit" ]; then
        printf '%s\n' "$hit"
        return 0
    fi
    hit=$(find "$d" -type f \( -iname '*.png' -o -iname '*.svg' -o -iname '*.xpm' \) \
          2>/dev/null | LC_ALL=C sort | head -n 1)
    if [ -n "$hit" ]; then
        printf '%s\n' "$hit"
    else
        printf '%s\n' "$icon"
    fi
}

# --- PHASE 1: extraction and menu generation -------------------------------
extract_and_list() {
    local appimage filename appname target stage

    mkdir -p "$EXTRACT_DIR" 2>/dev/null
    if [ ! -d "$EXTRACT_DIR" ]; then
        notify dialog-error "AppImage Manager" "Cannot create $EXTRACT_DIR"
        return 0
    fi

    # Housekeeping: staging dirs left by runs killed mid-extract (>1 h old),
    # and the shared squashfs-root dir the old script version left behind.
    find "$EXTRACT_DIR" -maxdepth 1 -type d -name '.stage.*' -mmin +60 \
        -exec rm -rf -- {} + 2>/dev/null
    if [ -e "$EXTRACT_DIR/squashfs-root" ]; then
        rm -rf -- "$EXTRACT_DIR/squashfs-root"
    fi

    while IFS= read -r -d '' appimage; do
        filename=${appimage##*/}
        appname=${filename%.[aA][pP][pP][iI][mM][aA][gG][eE]}
        # A file literally named ".AppImage" yields an empty stem, which
        # used to make target collapse onto $EXTRACT_DIR itself -- the
        # rm -rf below then wiped every extracted app.  Skip such stems.
        case $appname in
            ''|.|..) continue ;;
        esac
        target=$EXTRACT_DIR/$appname

        if [ -d "$target" ] && ! [ "$appimage" -nt "$target" ]; then
            continue
        fi

        notify dialog-information "AppImage Manager" "Extracting $filename...
This may take a moment."

        # Private staging dir per invocation (hidden, so the menu glob
        # never sees it; on the same filesystem, so mv is an atomic
        # rename).  Concurrent rofi calls can no longer clobber each
        # other's squashfs-root.
        stage=$(mktemp -d "$EXTRACT_DIR/.stage.XXXXXX") || stage=
        if [ -z "$stage" ]; then
            notify dialog-error "AppImage Manager" "Failed to create staging dir for $filename."
            continue
        fi

        chmod +x "$appimage" 2>/dev/null
        # --appimage-extract unpacks to ./squashfs-root of the CURRENT
        # directory, so extract inside the staging dir (subshell: no
        # persistent cd, and a failure cannot abort the whole menu).
        if ( cd "$stage" && "$appimage" --appimage-extract ) >/dev/null 2>&1 \
           && [ -d "$stage/squashfs-root" ]; then
            # Belt and braces: never rm anything outside $EXTRACT_DIR.
            case $target in
                "$EXTRACT_DIR"/*) rm -rf -- "$target" ;;
            esac
            if mv "$stage/squashfs-root" "$target" 2>/dev/null; then
                # Remember which AppImage produced this dir, so phase 2
                # does not have to guess the file name back.
                printf '%s\n' "$appimage" > "$target/.source"
                notify dialog-information "AppImage Manager" "Successfully extracted $filename!"
            else
                notify dialog-error "AppImage Manager" "Failed to install $filename."
            fi
        else
            notify dialog-error "AppImage Manager" "Failed to extract $filename."
        fi
        rm -rf -- "$stage"
    done < <(find "$APPDIR" -maxdepth 1 -iname '*.appimage' -print0 2>/dev/null)

    # One rofi entry per extracted app.
    local dir appname desktop_file name icon icon_path
    for dir in "$EXTRACT_DIR"/*/; do
        [ -d "$dir" ] || continue
        appname=$(basename "$dir")
        desktop_file=$(app_desktop_file "$dir" "$appname")
        [ -n "$desktop_file" ] || continue

        name=$(app_display_name "$dir" "$appname")
        icon=$(desktop_field "Icon" "$desktop_file")
        icon_path=$(app_icon "$dir" "$icon")

        if [ -n "$icon_path" ]; then
            printf '%s\0icon\x1f%s\n' "$name" "$icon_path"
        else
            printf '%s\n' "$name"
        fi
    done
}

# --- PHASE 2: launch the selected entry ------------------------------------
launch_selected() {
    local selected=$*
    local dir appname desktop_file name src

    for dir in "$EXTRACT_DIR"/*/; do
        [ -d "$dir" ] || continue
        dir=${dir%/}  # glob yields a trailing slash; keep APPDIR env clean
        appname=$(basename "$dir")
        desktop_file=$(app_desktop_file "$dir" "$appname")
        [ -n "$desktop_file" ] || continue
        name=$(app_display_name "$dir" "$appname")

        if [ "$name" = "$selected" ]; then
            src=
            if [ -r "$dir/.source" ]; then
                src=$(head -n 1 "$dir/.source")
            fi
            if [ -z "$src" ] || [ ! -f "$src" ]; then
                # Dirs extracted by older script versions have no .source
                # pointer; fall back to a stem lookup.
                src=$(find "$APPDIR" -maxdepth 1 -iname "$appname.appimage" \
                      2>/dev/null | head -n 1)
            fi
            # Run the app from the EXTRACTED copy: AppRun is the entry
            # point the AppImage runtime itself would exec, and it sets up
            # everything the bundled binaries need (library paths, and so
            # on).  Export the variables the runtime normally provides, so
            # AppRun scripts that expect them keep working.
            if [ -f "$dir/AppRun" ]; then
                chmod +x "$dir/AppRun" 2>/dev/null
                if [ -x "$dir/AppRun" ]; then
                    if [ -n "$src" ] && [ -f "$src" ]; then
                        APPDIR=$dir APPIMAGE=$src \
                            nohup "$dir/AppRun" >/dev/null 2>&1 &
                    else
                        APPDIR=$dir nohup "$dir/AppRun" >/dev/null 2>&1 &
                    fi
                    exit 0
                fi
            fi

            # No runnable AppRun in the extracted copy -- fall back to the
            # packed AppImage rather than failing outright.
            if [ -n "$src" ] && [ -f "$src" ]; then
                chmod +x "$src" 2>/dev/null
                nohup "$src" >/dev/null 2>&1 &
                exit 0
            fi
            notify dialog-error "AppImage Manager" \
                "Cannot launch '$selected': no runnable AppRun or AppImage found."
            exit 0
        fi
    done
    notify dialog-error "AppImage Manager" "No AppImage matches '$selected'."
}

if [ "$#" -eq 0 ]; then
    extract_and_list
else
    # A function has its own positional parameters, so $* must be handed
    # over explicitly instead of being read inside the function.
    launch_selected "$@"
fi
