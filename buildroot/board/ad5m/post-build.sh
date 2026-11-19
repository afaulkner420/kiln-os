#!/bin/sh
# Runs after the target tree is assembled ($1 = target dir). Adventurer 5M.
# WORK IN PROGRESS, NOT BUILT YET. Modelled on board/ad5x/post-build.sh, without the vendor
# bundling and the recovery OS (the AD5M has neither yet: docs/ad5m-boot.md):
# - Drops Buildroot's S50nginx and sample pages: S63nginx starts nginx.
# - Makes Klipper's prebuilt c_helper.so newer than its sources, so klippy doesn't try to
#   rebuild it (the printer has no compiler).
# - Compiles Klipper and Moonraker to bytecode (a read-only use of the root is the goal).
# - Writes /etc/kiln-version, /etc/ad5x-release and the os-release name.
set -e
TARGET=$1
REPO=$(cd "$BR2_EXTERNAL_AD5X_PATH/.." && pwd)

rm -f "$TARGET/etc/init.d/S50nginx" "$TARGET/etc/logrotate.d/nginx"
rm -rf "$TARGET/usr/html"

# Python libraries' test suites, type stubs and C headers: nothing on the printer uses them
PYLIB=$(ls -d "$TARGET"/usr/lib/python3.* 2>/dev/null | head -1)
if [ -n "$PYLIB" ]; then
	find "$PYLIB/site-packages" -depth -type d \( -name tests -o -name test \) \
		-exec rm -rf {} + 2>/dev/null || true
	find "$PYLIB" \( -name '*.pyi' -o -name py.typed \) -delete
	if [ -f "$PYLIB/os.pyc" ]; then
		find "$PYLIB" -depth -type d -name __pycache__ -exec rm -rf {} +
	fi
	rm -rf "$PYLIB/ensurepip" "$PYLIB/site-packages/numpy/f2py" \
		"$PYLIB/site-packages/numpy/_core/include" \
		"$PYLIB"/site-packages/numpy/_pyinstaller
fi

# git: only what cloning and updating a plugin over https needs
GC=$TARGET/usr/libexec/git-core
if [ -d "$GC" ]; then
	for f in "$GC"/*; do
		[ "$f" -ef "$TARGET/usr/bin/git" ] && continue
		case ${f##*/} in
		git-remote-http|git-remote-https|git-sh-setup|git-sh-i18n) ;;
		*) rm -rf "$f" ;;
		esac
	done
	rm -rf "$TARGET/usr/share/gitweb" "$TARGET/usr/share/git-core/templates/hooks" \
		"$TARGET/usr/bin/scalar" "$TARGET/usr/bin/git-shell" \
		"$TARGET/usr/bin/git-upload-archive" "$TARGET/usr/bin/git-cvsserver"
fi

# Version: AD5X_VERSION (tools/ad5m-build-all.sh sets it), else from git
KVER=${AD5X_VERSION:-}
KCOMMIT=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)
if [ -z "$KVER" ]; then
	d=$(git -C "$REPO" describe --tags --long --match 'v[0-9]*' 2>/dev/null || true)
	if [ -n "$d" ]; then
		KVER=$(echo "$d" | sed 's/^\(.*\)-\([0-9]*\)-g\([0-9a-f]*\)$/\1+\2.g\3/')
	else
		KVER="v0.0.0+ad5m.g$(echo "$KCOMMIT" | cut -c1-7)"
	fi
fi
KDATE=$(date -u +%Y-%m-%d)
printf 'VERSION=%s\nCOMMIT=%s\nDATE=%s\nBOARD=ad5m\n' "$KVER" "$KCOMMIT" "$KDATE" > "$TARGET/etc/kiln-version"
echo "Kiln OS $KVER ($KDATE), Adventurer 5M" > "$TARGET/etc/ad5x-release"
echo 'VERSION_CODENAME="AD5M"' >> "$TARGET/usr/lib/os-release"
sed -i -e 's/^NAME=.*/NAME="Kiln OS"/' \
	-e "s/^PRETTY_NAME=.*/PRETTY_NAME=\"Kiln OS $KVER ($KDATE)\"/" \
	"$TARGET/usr/lib/os-release"
api=$(sed -n 's/^PLUGIN_API_VERSION = "\(.*\)"$/\1/p' \
	"$TARGET/usr/lib/klipper/klippy/extras/ad5x_plugins.py" 2>/dev/null)
if [ -n "$api" ]; then
	echo "AD5X_PLUGIN_API=\"$api\"" >> "$TARGET/usr/lib/os-release"
fi

CH=$TARGET/usr/lib/klipper/klippy/chelper
if [ -f "$CH/c_helper.so" ]; then
	touch -d '+1 day' "$CH/c_helper.so" 2>/dev/null || touch "$CH/c_helper.so"
fi

for d in usr/lib/klipper usr/lib/moonraker; do
	[ -d "$TARGET/$d" ] || continue
	"$HOST_DIR/bin/python3" -m compileall -q -j 0 \
		--invalidation-mode unchecked-hash "$TARGET/$d" >/dev/null
done
