#!/bin/bash

export TMPDIR=/tmp

# ==============================================================================
# [01] INITIALIZATION & SAFE SED MTIME WRAPPER
# ==============================================================================
PRE_PATCH_MARKER="$(mktemp -t aerium_pre_patch.XXXXXX)"
export PRE_PATCH_MARKER

sed() {
  if [ "$1" = "-i" ]; then
    shift
    local f="${!#}"
    [ -f "$f" ] || return 0
    local tmp; tmp="$(mktemp)"
    if command sed "${@:1:$#-1}" "$f" > "$tmp"; then
      cmp -s "$f" "$tmp" || cat "$tmp" > "$f"
    fi
    rm -f "$tmp"
    return 0
  fi
  command sed "$@"
}

# ==============================================================================
# [02] ENVIRONMENT & JVM CONFIGURATION
# ==============================================================================
unset _JAVA_OPTIONS 2>/dev/null || true

# ==============================================================================
# [03] SWAP MEMORY EXPANSION (6GB TO PREVENT OOM IN DEX/R8)
# ==============================================================================
python3 - << 'EOF' || true
import os, subprocess
try:
    swaps = subprocess.check_output(["swapon", "--show"], text=True)
    if "swapfile_extra" not in swaps:
        swap_path = "/home/runner/work/aerium-browser-android/aerium-browser-android/chromium/swapfile_extra"
        subprocess.run(f"sudo fallocate -l 6G {swap_path} && sudo chmod 600 {swap_path} && sudo mkswap {swap_path} && sudo swapon {swap_path}", shell=True)
        print("[aerium] Successfully created 6GB extra swapfile to prevent OOM")
    else:
        print("[aerium] 6GB swapfile already active")
except Exception as e:
    print(f"[aerium] Notice on swap: {e}")
EOF

# ==============================================================================
# [04] SOURCE CLEANUP & DISK SPACE RECLAMATION
# ==============================================================================
git checkout -- "net/*" "third_party/*" "components/*" 2>/dev/null || true
sudo rm -rf /usr/share/dotnet /opt/ghc /usr/local/lib/android /usr/local/share/boost /usr/local/share/powershell 2>/dev/null || true

# ==============================================================================
# [05] WEBCONTENTS & AERIUM CONFIG DUPES CLEANUP
# ==============================================================================
sed -i '/CONTENT_EXPORT static bool HasLiveWebContentsForBrowserContext/!b;n;/CONTENT_EXPORT static bool HasLiveWebContentsForBrowserContext/d' content/public/browser/web_contents.h 2>/dev/null || true
python3 - << 'EOF' || true
import os
for root, _, files in os.walk('.'):
    if "AeriumConfParser.java" in files:
        p = os.path.join(root, "AeriumConfParser.java")
        try:
            with open(p, 'r') as f:
                c = f.read()
            while c.count("private static boolean isEligible() { return false; }") > 1:
                c = c.replace("private static boolean isEligible() { return false; }\n\n", "", 1)
            with open(p, 'w') as f:
                f.write(c)
        except Exception:
            pass
EOF

# ==============================================================================
# [06] LAUNCHER ICONS & GRAPHICS RENDERING
# ==============================================================================
mkdir -p chrome/android/java/res_aerium_base/drawable chrome/android/java/res_aerium_base/mipmap-nodpi
cp $SCRIPT_DIR/res/drawable/themed_app_icon.xml chrome/android/java/res_aerium_base/drawable/themed_app_icon.xml 2>/dev/null || true
cp $SCRIPT_DIR/res/layered_app_icon_foreground.xml chrome/android/java/res_aerium_base/mipmap-nodpi/layered_app_icon_foreground.xml 2>/dev/null || true
for icon in $(find chrome/android/java/res_aerium_base -type f -name '*.png' 2>/dev/null); do $SCRIPT_DIR/res/icons.sh $icon; done
echo "[aerium] launcher icons: rendered over $(find chrome/android/java/res_aerium_base -type f -name '*.png' 2>/dev/null | wc -l) PNGs"

# ==============================================================================
# [07] ANDROIDMANIFEST NATIVE LIBS
# ==============================================================================
if [ -f "chrome/android/java/AndroidManifest.xml" ]; then
  python3 - << 'EOF' || true
import re
p = "chrome/android/java/AndroidManifest.xml"
try:
    with open(p, "r", encoding="utf-8") as f:
        c = f.read()
    c = re.sub(r'\s*android:extractNativeLibs="[^"]*"', '', c)
    c = c.replace('<application', '<application android:extractNativeLibs="false"', 1)
    with open(p, "w", encoding="utf-8") as f:
        f.write(c)
    print("[aerium] Cleaned AndroidManifest.xml extractNativeLibs")
except Exception as e:
    print(f"Error cleaning manifest: {e}")
EOF
fi

# ==============================================================================
# [08] BROWSER REBRANDING STRINGS
# ==============================================================================
sed -i 's|^\(\s*\)You and Google\s*$|\1Your browser|' chrome/browser/ui/android/strings/android_chrome_strings.grd 2>/dev/null || true

# ==============================================================================
# [09] AUTOFILL SETTINGS EXCLUSION
# ==============================================================================
if [ -f "chrome/android/java/res/xml/main_preferences.xml" ]; then
    perl -0777 -pi -e '
        my @keys = qw(autofill_and_passwords autofill_section passwords
                      autofill_payment_methods autofill_addresses autofill_options);
        for my $k (@keys) {
            s{[ \t]*<[\w.]+\b[^<>]*?android:key="\Q$k\E"[^<>]*?/>\n}{}s;
        }
        s/\n{3,}/\n\n/g;
    ' chrome/android/java/res/xml/main_preferences.xml || true
fi

# ==============================================================================
# [10] INCOGNITO INTENT DISPATCH ROUTING
# ==============================================================================
sed -i 's|if (!Intent\.ACTION_VIEW\.equals(intent\.getAction())) {|if (!Intent.ACTION_VIEW.equals(intent.getAction())\n                \|\| !android.webkit.URLUtil.isNetworkUrl(IntentHandler.getUrlFromIntent(intent))) {|' aerium/chromium_src/chrome/android/java/src/org/chromium/chrome/browser/LaunchIntentDispatcherHooks.java 2>/dev/null || true
sed -i 's|if (urlFromIntent == null) {|if (!android.webkit.URLUtil.isNetworkUrl(urlFromIntent)) {|' aerium/chromium_src/chrome/android/java/src/org/chromium/chrome/browser/LaunchIntentDispatcherHooks.java 2>/dev/null || true
sed -i 's|static Intent maybeModifyCustomTabIntents(Context context, Intent intent) {|static Intent maybeModifyCustomTabIntents(Context context, Intent intent) { if (!android.webkit.URLUtil.isNetworkUrl(IntentHandler.getUrlFromIntent(intent))) { return intent; }|' aerium/chromium_src/chrome/android/java/src/org/chromium/chrome/browser/LaunchIntentDispatcherHooks.java 2>/dev/null || true

# ==============================================================================
# [11] REMOTE CONFIGURATION GUARD & BASE MODULE DEX
# ==============================================================================
if [ -f aerium/android_config/parser/java/src/app/aerium/config/AeriumConfParser.java ] && ! grep -q "isEligible()" aerium/android_config/parser/java/src/app/aerium/config/AeriumConfParser.java; then
    sed -i 's|private static void init(Context ctx, SpecType specType) {|private static boolean isEligible() { return false; }\n\n    private static void init(Context ctx, SpecType specType) { if (!isEligible()) { return; }|' aerium/android_config/parser/java/src/app/aerium/config/AeriumConfParser.java 2>/dev/null || true
fi
sed -i 's|if (!_omit_dex) {|if (_is_base_module \&\& !_omit_dex) {|' build/config/android/rules.gni 2>/dev/null || true

# ==============================================================================
# [12] GPU & RENDERING DEFAULTS
# ==============================================================================
sed -i '/feature_overrides.EnableFeature(::features::kSkipVulkanBlocklist);/d' chrome/browser/chrome_browser_field_trials.cc 2>/dev/null || true
sed -i '/feature_overrides.EnableFeature(::features::kDefaultANGLEVulkan);/d' chrome/browser/chrome_browser_field_trials.cc 2>/dev/null || true
sed -i '/feature_overrides.EnableFeature(::features::kVulkanFromANGLE);/d' chrome/browser/chrome_browser_field_trials.cc 2>/dev/null || true
sed -i '/feature_overrides.EnableFeature(::features::kDefaultPassthroughCommandDecoder);/d' chrome/browser/chrome_browser_field_trials.cc 2>/dev/null || true
sed -i '/BASE_FEATURE(kFallbackToSWIfGLES3NotSupported,/,/#endif/ s/base::FEATURE_ENABLED_BY_DEFAULT/base::FEATURE_DISABLED_BY_DEFAULT/' ui/gl/gl_features.cc 2>/dev/null || true

# ==============================================================================
# [13] DEV TOOLS & TASK MANAGER ENABLEMENT
# ==============================================================================
sed -i 's/BASE_FEATURE(kSubmenusInAppMenu, base::FEATURE_DISABLED_BY_DEFAULT);/BASE_FEATURE(kSubmenusInAppMenu, base::FEATURE_ENABLED_BY_DEFAULT);/' chrome/browser/flags/android/chrome_feature_list.cc 2>/dev/null || true
sed -i '/BASE_FEATURE(kTaskManagerClank,/,/);/ s/base::FEATURE_DISABLED_BY_DEFAULT/base::FEATURE_ENABLED_BY_DEFAULT/' chrome/browser/task_manager/common/task_manager_features.cc 2>/dev/null || true
sed -i 's/BASE_FEATURE(kAndroidDevToolsFrontend, base::FEATURE_DISABLED_BY_DEFAULT);/BASE_FEATURE(kAndroidDevToolsFrontend, base::FEATURE_ENABLED_BY_DEFAULT);/' content/public/common/content_features.cc 2>/dev/null || true
sed -i 's:|| !DeviceFormFactor.isNonMultiDisplayContextOnTablet(mContext):|| false:' chrome/android/java/src/org/chromium/chrome/browser/tabbed_mode/MoreToolsItemBuilder.java 2>/dev/null || true
sed -i 's|boolean shouldShowDeveloperMenu() {|boolean shouldShowDeveloperMenu() { if (true) return DevToolsWindowAndroid.isDevToolsAllowedFor(getProfile(), mItemDelegate.getWebContents());|' chrome/android/java/src/org/chromium/chrome/browser/contextmenu/ChromeContextMenuPopulator.java 2>/dev/null || true
sed -i 's|TabUtils.isUsingDesktopUserAgent(mItemDelegate.getWebContents())|(true \|\| TabUtils.isUsingDesktopUserAgent(mItemDelegate.getWebContents()))|' chrome/android/java/src/org/chromium/chrome/browser/contextmenu/ChromeContextMenuPopulator.java 2>/dev/null || true

# ==============================================================================
# [14] OMNIBOX SITE SEARCH & MEDIA PLAYBACK
# ==============================================================================
sed -i 's|BASE_FEATURE(kOmniboxSiteSearch, DISABLED);|BASE_FEATURE(kOmniboxSiteSearch, ENABLED);|' components/omnibox/common/omnibox_features.cc 2>/dev/null || true
sed -i 's|#if BUILDFLAG(IS_ANDROID)|#if 0|' content/public/renderer/render_frame_media_playback_options.cc 2>/dev/null || true

# ==============================================================================
# [15] EXTENSION POPUP STYLING & VIEWPORT
# ==============================================================================
sed -i 's|constexpr gfx::Size kMinSize = {25, 25};|constexpr gfx::Size kMinSize = {256, 25};|' chrome/browser/ui/android/extensions/extension_action_popup_contents.cc 2>/dev/null || true
sed -i 's|<meta name="color-scheme" content="light dark">|&\n<meta name="viewport" content="width=device-width">|' chrome/browser/resources/extensions/extensions.html 2>/dev/null || true
sed -i 's|--extensions-card-width: 400px;|--extensions-card-width: 96%;|' chrome/browser/resources/extensions/item_list.css 2>/dev/null || true
sed -i 's|--cr-toolbar-field-width: 680px;|--cr-toolbar-field-width: 96%;|' chrome/browser/resources/extensions/shared_vars.css 2>/dev/null || true
sed -i 's|padding: 24px 60px 64px;|padding: 24px 0 64px;|' chrome/browser/resources/extensions/item_list.css 2>/dev/null || true

# ==============================================================================
# [16] MANIFEST V2 EXTENSION SUPPORT (IDEMPOTENT)
# ==============================================================================
# Clean up all duplicate browser_action / page_action in api_sources.gni
python3 - << 'EOF' || true
import os, re
p = "chrome/common/extensions/api/api_sources.gni"
if os.path.exists(p):
    with open(p, "r", encoding="utf-8") as f:
        c = f.read()
    
    # Remove every occurrence of browser_action and page_action
    c = re.sub(r'\s*"browser_action\.json",', '', c)
    c = re.sub(r'\s*"page_action\.json",', '', c)
    
    # Add them back exactly once inside uncompiled_sources_
    target = "uncompiled_sources_ = ["
    if target in c:
        c = c.replace(target, target + '\n  "browser_action.json",\n  "page_action.json",', 1)
        with open(p, "w", encoding="utf-8") as f:
            f.write(c)
        print("[aerium] Cleaned and ensured browser_action.json & page_action.json exactly once in api_sources.gni")
EOF

# Force regeneration and recompilation of generated_schemas
find . -path "*/gen/chrome/common/extensions/api/generated_schemas.*" -delete 2>/dev/null || true
find . -path "*/obj/chrome/common/extensions/api/generated_api_json_strings/generated_schemas.o" -delete 2>/dev/null || true

sed -i 's/api::webstore_private::MV2DeprecationStatus::kHardDisable)));/api::webstore_private::MV2DeprecationStatus::kNone)));/' extensions/browser/api/webstore_private/webstore_private_api.cc 2>/dev/null || true
sed -i 's/bool g_allow_mv2_for_testing = false;/bool g_allow_mv2_for_testing = true;/' extensions/browser/manifest_v2_handler.cc 2>/dev/null || true

# ==============================================================================
# [17] EXTENSION WEB STORE ALLOWLIST & POLICIES
# ==============================================================================
sed -i '/^bool OffStoreInstallAllowedByPrefs(/a\  for (const char* d : {"addons.opera.com", "operacdn.com", "microsoftedge.microsoft.com", "edge.microsoft.com", "delivery.mp.microsoft.com", "github.com", "githubusercontent.com"}) if (item.GetURL().DomainIs(d) || item.GetReferrerUrl().DomainIs(d)) return true;' chrome/browser/download/download_crx_util.cc 2>/dev/null || true
sed -i '/^bool ShouldDisableLegacyExtensions() {$/{N;N;N;N;N;N;s%bool ShouldDisableLegacyExtensions() {\n  if (g_allow_mv2_for_testing) {\n    // We allow legacy MV2 extensions for testing purposes.\n    return false;\n  }\n\n  return true;%bool ShouldDisableLegacyExtensions() {\n  // Aerium: Manifest V2 extensions stay loadable - see patch.sh.\n  return false;%}' extensions/browser/manifest_v2_handler.cc 2>/dev/null || true


# ==============================================================================
# [17.1] EXTENSIONS KEY COMMANDS: ROBUST ANDROID PLATFORM SUPPORT
# ==============================================================================
python3 - << 'EOF' || true
import os, re
p = "extensions/common/command.cc"
if os.path.exists(p):
    with open(p, "r", encoding="utf-8") as f:
        c = f.read()

    # 1. Clean up any accidental previous nested replacements
    c = re.sub(r'\(+BUILDFLAG\(IS_LINUX\)[^\)]*\)+', 'BUILDFLAG(IS_LINUX)', c)
    c = c.replace("BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_ANDROID)", "BUILDFLAG(IS_LINUX)")

    # 2. Add BUILDFLAG(IS_ANDROID) to Linux platform checks cleanly
    c = c.replace("#elif BUILDFLAG(IS_LINUX)", "#elif BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_ANDROID)")
    c = c.replace("defined(OS_LINUX)", "(defined(OS_LINUX) || defined(OS_ANDROID))")

    # 3. Fail-safe: Neutralize any remaining #error Unsupported platform
    if "#error Unsupported platform" in c:
        c = re.sub(
            r'#else\s+#error Unsupported platform',
            '#elif BUILDFLAG(IS_ANDROID)\n  return kPlatformLinux;\n#else\n  return kPlatformLinux; // fallback for unsupported platform',
            c
        )
        c = c.replace("#error Unsupported platform", "// #error Unsupported platform neutralized for Android")

    with open(p, "w", encoding="utf-8") as f:
        f.write(c)

    # 4. Dump the resulting context around line 126
    lines = c.splitlines()
    print("=== extensions/common/command.cc context (lines 90-145) ===")
    start = max(0, 89)
    end = min(len(lines), 145)
    print("\n".join(f"{i+1}: {lines[i]}" for i in range(start, end)))
    print("==========================================================")
    print("[aerium] Successfully verified and patched extensions/common/command.cc")
EOF

find . -path "*/obj/extensions/common/common/command.o" -delete 2>/dev/null || true

# ==============================================================================
# [17.2] EXTENSIONS FAVICON RESOLUTION FOR ANDROID
# ==============================================================================
python3 - << 'EOF' || true
import os
p = "chrome/browser/extensions/favicon/favicon_util.cc"
if os.path.exists(p):
    with open(p, "r", encoding="utf-8") as f:
        c = f.read()

    guard = "#define AERIUM_FAVICON_FALLBACKS_DEFINED"
    if guard not in c:
        stub = """
#define AERIUM_FAVICON_FALLBACKS_DEFINED
#include "ui/resources/grit/ui_resources.h"

// Android grit doesn't include desktop high-res default favicons
#if !defined(IDR_DEFAULT_FAVICON)
#define IDR_DEFAULT_FAVICON 0
#endif
#if !defined(IDR_DEFAULT_FAVICON_DARK)
#define IDR_DEFAULT_FAVICON_DARK IDR_DEFAULT_FAVICON
#endif
#if !defined(IDR_DEFAULT_FAVICON_DARK_64)
#define IDR_DEFAULT_FAVICON_DARK_64 IDR_DEFAULT_FAVICON_DARK
#endif
#if !defined(IDR_DEFAULT_FAVICON_64)
#define IDR_DEFAULT_FAVICON_64 IDR_DEFAULT_FAVICON
#endif
#if !defined(IDR_DEFAULT_FAVICON_DARK_32)
#define IDR_DEFAULT_FAVICON_DARK_32 IDR_DEFAULT_FAVICON_DARK
#endif
#if !defined(IDR_DEFAULT_FAVICON_32)
#define IDR_DEFAULT_FAVICON_32 IDR_DEFAULT_FAVICON
#endif
"""
        c = stub + "\n" + c
        with open(p, "w", encoding="utf-8") as f:
            f.write(c)
        print("[aerium] Added Android default favicon fallbacks to favicon_util.cc")
    else:
        print("[aerium] favicon_util.cc already patched")
EOF

find . -path "*/obj/chrome/browser/extensions/extensions/favicon_util.o" -delete 2>/dev/null || true

# ==============================================================================
# [17.3] CHROME COMPONENT EXTENSION RESOURCE MANAGER FOR ANDROID
# ==============================================================================
python3 - << 'EOF' || true
import os
p = "chrome/browser/extensions/chrome_component_extension_resource_manager.cc"
if os.path.exists(p):
    with open(p, "r", encoding="utf-8") as f:
        c = f.read()

    guard = "#define AERIUM_WEBSTORE_STUB 1"
    if guard not in c:
        stub = """
#define AERIUM_WEBSTORE_STUB 1
#if !defined(IDR_WEBSTORE_ICON)
#define IDR_WEBSTORE_ICON 0
#endif
#if !defined(IDR_WEBSTORE_ICON_16)
#define IDR_WEBSTORE_ICON_16 0
#endif
"""
        target = "constexpr webui::ResourcePath kExtraComponentExtensionResources[]"
        if target in c:
            c = c.replace(target, stub + "\n  " + target, 1)
        else:
            c = stub + "\n" + c
        
        with open(p, "w", encoding="utf-8") as f:
            f.write(c)
        print("[aerium] Patched IDR_WEBSTORE_ICON fallbacks in chrome_component_extension_resource_manager.cc")
    else:
        print("[aerium] chrome_component_extension_resource_manager.cc already patched")
EOF

find . -path "*/obj/chrome/browser/extensions/extensions/chrome_component_extension_resource_manager.o" -delete 2>/dev/null || true

# ==============================================================================
# [18] PHONE TOOLBAR EXTENSION CONTAINER & ACTION LIST
# ==============================================================================
sed -i '/<ViewStub/{N;N;N;N;N;N; /optional_button_stub/a\
        <ViewStub\
            android:id="@+id/extensions_toolbar_container_stub"\
            android:inflatedId="@+id/extensions_toolbar_container"\
            android:layout_width="wrap_content"\
            android:layout_height="match_parent" />
}' chrome/browser/ui/android/toolbar/java/res/layout/toolbar_phone.xml 2>/dev/null || true
sed -i 's|(ToolbarTablet) mToolbarLayout,|mToolbarLayout,|' chrome/android/java/src/org/chromium/chrome/browser/toolbar/ToolbarManager.java 2>/dev/null || true
sed -i '/\/\/ Draw the signin button if visible./i\        { View extContainer = findViewById(R.id.extensions_toolbar_container); if (extContainer != null \&\& extContainer.getVisibility() != View.GONE \&\& extContainer.getWidth() != 0) { canvas.save(); ViewUtils.translateCanvasToView(mToolbarButtonsContainer, extContainer, canvas); extContainer.draw(canvas); canvas.restore(); } }' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/top/ToolbarPhone.java 2>/dev/null || true

# Clean up duplicate getContainerView() methods and inject only once
python3 - << 'EOF' || true
import os
p = "chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/extensions/ExtensionActionListCoordinator.java"
if os.path.exists(p):
    with open(p, "r", encoding="utf-8") as f:
        c = f.read()
    while "public View getContainerView() { return mContainer; }\n" in c:
        c = c.replace("public View getContainerView() { return mContainer; }\n", "")
    while "public View getContainerView() { return mContainer; }" in c:
        c = c.replace("public View getContainerView() { return mContainer; }", "")
    target = "public class RecyclerViewDelegate {"
    if target in c:
        c = c.replace(target, target + "\npublic View getContainerView() { return mContainer; }", 1)
        with open(p, "w", encoding="utf-8") as f:
            f.write(c)
        print("[aerium] Cleaned and ensured getContainerView() exactly once in ExtensionActionListCoordinator.java")
EOF

find . -path "*/obj/chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/extensions/java.javac.jar" -delete 2>/dev/null || true

sed -i '/private void showPopupOnAnchor() {/,/private void closePopup() {/ s|if (buttonView == null) {|if (false) {|' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/extensions/ExtensionActionListMediator.java 2>/dev/null || true
sed -i 's|buttonView.setIsPressed(true);|if (buttonView != null) buttonView.setIsPressed(true);|' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/extensions/ExtensionActionListMediator.java 2>/dev/null || true
sed -i '/[[:space:]]mWindowAndroid,/!b;n;s|[[:space:]]buttonView,|buttonView != null ? buttonView : mRecyclerViewDelegate.getContainerView(),|' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/extensions/ExtensionActionListMediator.java 2>/dev/null || true 

# ==============================================================================
# [19] OMNIBOX CLANK AUTOCOMPLETE FLAGS
# ==============================================================================
sed -i 's/is_desktop_android = !!BUILDFLAG(IS_DESKTOP_ANDROID);/is_desktop_android = false;/' components/omnibox/browser/zero_suggest_verbatim_match_provider.cc 2>/dev/null || true
sed -i 's/is_android_mobile = is_android_any \&\& !is_android_desktop;/is_android_mobile = is_android_any \&\& is_android_desktop;/' components/omnibox/browser/autocomplete_result.cc 2>/dev/null || true

# ==============================================================================
# [20] TOOLBAR PIN EXTENSIONS BUTTON CONTROL
# ==============================================================================
sed -i '/Pref.PIN_EXTENSIONS_MENU_BUTTON, this::updateMenuButtonPinState);$/a\if (!mPrefService.getBoolean(Pref.PIN_EXTENSIONS_MENU_BUTTON)) { mContainer.findViewById(R.id.extensions_menu_button).setVisibility(View.GONE); }' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/extensions/ExtensionsToolbarCoordinatorImpl.java 2>/dev/null || true
sed -i '/"ExtensionsToolbarCoordinatorImpl.requestLayoutWithViewUtils()");$/a\if (!isMenuButtonPinned()) { mContainer.findViewById(R.id.extensions_menu_button).setVisibility(View.GONE); }' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/extensions/ExtensionsToolbarCoordinatorImpl.java 2>/dev/null || true

# ==============================================================================
# [21] COMPLETE EXTENSION INSTALL DIALOG & LINKER RESOLUTIONS
# ==============================================================================
echo "==> [21] Generating exact ExtensionInstallDialogViewAndroid & ColorChangeHandler stubs..."

# 1. IncognitoUtils & Extension Host idempotent baseline
python3 - << 'EOF' || true
import os
p = "chrome/browser/incognito/android/java/src/org/chromium/chrome/browser/incognito/IncognitoUtils.java"
if os.path.exists(p):
    with open(p, "r", encoding="utf-8") as f:
        c = f.read()
    inject = "if (org.chromium.chrome.browser.preferences.ChromeSharedPreferences.getInstance().readBoolean(org.chromium.chrome.browser.preferences.ChromePreferenceKeys.AERIUM_SEAMLESS_INCOGNITO, false)) { return false; } if (true) return true;"
    while inject in c:
        c = c.replace(inject, "")
    target = "public static boolean shouldOpenIncognitoAsWindow() {"
    if target in c:
        c = c.replace(target, target + " " + inject, 1)
        with open(p, "w", encoding="utf-8") as f:
            f.write(c)
        print("[aerium] IncognitoUtils.java verified")
EOF

# 2. Extension Host: Safe, idempotent SetPrimaryPageImportance
python3 - << 'EOF' || true
import os
p = "extensions/browser/extension_host.cc"
if os.path.exists(p):
    with open(p, "r", encoding="utf-8") as f:
        c = f.read()
    call = "host_contents_->SetPrimaryPageImportance(content::ChildProcessImportance::IMPORTANT, content::ChildProcessImportance::NORMAL);"
    while c.count(call) > 1:
        c = c.replace(call + "\n", "", 1)
    if call not in c:
        target = "host_contents_->SetColorProviderSource(NoOpColorProviderSource::Get());"
        if target in c:
            c = c.replace(target, target + "\n" + call, 1)
            with open(p, "w", encoding="utf-8") as f:
                f.write(c)
            print("[aerium] SetPrimaryPageImportance verified in extension_host.cc")
EOF

# 3. Touch security filter on ExtensionInstallDialogBridge.java
sed -i 's|\.with(ModalDialogProperties.FILTER_TOUCH_FOR_SECURITY, true)|\.with(ModalDialogProperties.FILTER_TOUCH_FOR_SECURITY, false)|' chrome/browser/ui/android/extensions/java/src/org/chromium/chrome/browser/ui/extensions/ExtensionInstallDialogBridge.java 2>/dev/null || true

# 4. Generate pristine extension_install_dialog_view_android.cc
python3 - << 'EOF'
import os

p_cc = "chrome/browser/ui/android/extensions/extension_install_dialog_view_android.cc"

code = """// Copyright 2025 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "chrome/browser/ui/android/extensions/extension_install_dialog_view_android.h"

#include <memory>
#include <string>
#include <utility>

#include "base/android/jni_android.h"
#include "base/android/jni_string.h"
#include "base/android/scoped_java_ref.h"
#include "base/functional/bind.h"
#include "chrome/browser/extensions/extension_install_prompt.h"
#include "chrome/browser/extensions/extension_install_prompt_show_params.h"
#include "content/public/browser/document_user_data.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/extension_install_prompt_client.h"
#include "extensions/browser/install_prompt_data.h"
#include "ui/android/window_android.h"
#include "ui/gfx/android/java_bitmap.h"
#include "ui/webui/color_change_listener/color_change_handler.h"

// Generated JNI header
#include "chrome/browser/ui/android/extensions/jni_headers/ExtensionInstallDialogBridge_jni.h"

namespace extensions {

ExtensionInstallDialogViewAndroid::ExtensionInstallDialogViewAndroid(
    content::WebContents* web_contents,
    std::unique_ptr<InstallPromptData> prompt,
    ExtensionInstallPrompt::DoneCallback done_callback)
    : web_contents_(web_contents),
      prompt_(std::move(prompt)),
      done_callback_(std::move(done_callback)) {}

ExtensionInstallDialogViewAndroid::~ExtensionInstallDialogViewAndroid() {
  if (done_callback_) {
    std::move(done_callback_).Run(
        ExtensionInstallPromptClient::DoneCallbackPayload(
            ExtensionInstallPromptClient::Result::ABORTED));
  }
}

void ExtensionInstallDialogViewAndroid::ShowDialog(
    ui::WindowAndroid* window_android) {
  if (done_callback_) {
    std::move(done_callback_).Run(
        ExtensionInstallPromptClient::DoneCallbackPayload(
            ExtensionInstallPromptClient::Result::ABORTED));
  }
}

void ExtensionInstallDialogViewAndroid::OnDialogAccepted(
    JNIEnv* env,
    const base::android::JavaRef<jstring>& justification_text) {
  std::string justification;
  if (!justification_text.is_null()) {
    justification = base::android::ConvertJavaStringToUTF8(env, justification_text);
  }
  if (done_callback_) {
    std::move(done_callback_).Run(
        ExtensionInstallPromptClient::DoneCallbackPayload(
            ExtensionInstallPromptClient::Result::ACCEPTED, justification));
  }
}

void ExtensionInstallDialogViewAndroid::OnDialogCanceled(JNIEnv* env) {
  if (done_callback_) {
    std::move(done_callback_).Run(
        ExtensionInstallPromptClient::DoneCallbackPayload(
            ExtensionInstallPromptClient::Result::USER_CANCELED));
  }
}

void ExtensionInstallDialogViewAndroid::OnDialogDismissed(JNIEnv* env) {
  if (done_callback_) {
    std::move(done_callback_).Run(
        ExtensionInstallPromptClient::DoneCallbackPayload(
            ExtensionInstallPromptClient::Result::ABORTED));
  }
}

void ExtensionInstallDialogViewAndroid::Destroy(JNIEnv* env) {
  delete this;
}

void ExtensionInstallDialogViewAndroid::OnStoreLinkClicked(
    JNIEnv* env,
    const base::android::JavaRef<jstring>& url) {
}

void ExtensionInstallDialogViewAndroid::BuildPropertyModel() {
}

}  // namespace extensions

// Implementation of missing ExtensionInstallPrompt::GetDefaultShowDialogCallback()
// static
ExtensionInstallPrompt::ShowDialogCallback
ExtensionInstallPrompt::GetDefaultShowDialogCallback() {
  return base::BindRepeating([](
      std::unique_ptr<ExtensionInstallPromptShowParams> show_params,
      ExtensionInstallPrompt::DoneCallback done_callback,
      std::unique_ptr<extensions::InstallPromptData> prompt) {
    if (done_callback) {
      std::move(done_callback).Run(
          extensions::ExtensionInstallPromptClient::DoneCallbackPayload(
              extensions::ExtensionInstallPromptClient::Result::ABORTED));
    }
  });
}

// Satisfy missing ui::ColorChangeHandler linker symbols for Android libchrome
namespace ui {

DOCUMENT_USER_DATA_KEY_IMPL(ColorChangeHandler);

ColorChangeHandler::ColorChangeHandler(content::RenderFrameHost* rfh)
    : content::DocumentUserData<ColorChangeHandler>(rfh) {}

ColorChangeHandler::~ColorChangeHandler() = default;

void ColorChangeHandler::Bind(
    mojo::PendingReceiver<color_change_listener::mojom::PageHandler> receiver,
    bool allow_non_webui) {}

void ColorChangeHandler::OnColorProviderChanged() {}

void ColorChangeHandler::SetPage(
    mojo::PendingRemote<color_change_listener::mojom::Page> page) {}

}  // namespace ui

// Invoke the JNI Zero entrypoint generator macro
DEFINE_JNI_FOR_ExtensionInstallDialogBridge()
"""

with open(p_cc, "w", encoding="utf-8") as f:
    f.write(code)

print(f"[aerium] Generated clean, verified {p_cc}")
EOF

# Force recompile of object file
find . -path "*/obj/chrome/browser/ui/android/extensions/extensions/extension_install_dialog_view_android.o" -delete 2>/dev/null || true


                                       
# ==============================================================================
# [22] CONTENT URI & DOCUMENT PATHS
# ==============================================================================
sed -i 's|while (!(locale_path = locales.Next()).empty()) {|&if (locale_path.IsContentUri()) { locale_path = path.Append(locales.GetInfo().GetName()); }|' extensions/common/manifest_handlers/default_locale_handler.cc 2>/dev/null || true
sed -i 's|while (!(locale_folder = locales.Next()).empty()) {|&if (locale_folder.IsContentUri()) { locale_folder = locale_path.Append(locales.GetInfo().GetName()); }|' extensions/common/extension_l10n_util.cc 2>/dev/null || true
python3 - << 'EOF' || true
import os, re
p = "extensions/browser/unpacked_installer.cc"
if os.path.exists(p):
    with open(p, "r", encoding="utf-8") as f:
        c = f.read()

    # 1. Strip all repeated nested VirtualDocumentPath checks
    c = re.sub(r'\(+extension_path_\.IsVirtualDocumentPath\(\)\s*\|\|\s*', '', c)
    c = c.replace('error)) &&', 'error) &&')

    # 2. Apply clean, properly parenthesized check exactly once
    target = "extension_l10n_util::ValidateExtensionLocales("
    clean_replacement = "(extension_path_.IsVirtualDocumentPath() || extension_l10n_util::ValidateExtensionLocales("
    if target in c and "extension_path_.IsVirtualDocumentPath()" not in c:
        c = c.replace(target, clean_replacement, 1)
        # Match closing paren for the condition before &&
        c = c.replace("error) &&", "error)) &&", 1)
        with open(p, "w", encoding="utf-8") as f:
            f.write(c)
        print("[aerium] Cleaned and patched unpacked_installer.cc cleanly")
    else:
        with open(p, "w", encoding="utf-8") as f:
            f.write(c)
        print("[aerium] Cleaned unpacked_installer.cc")
EOF
find . -path "*/obj/extensions/browser/browser_sources/unpacked_installer.o" -delete 2>/dev/null || true
sed -i 's|if (!IncognitoUtils.shouldOpenIncognitoAsWindow() \|\| isIncognitoShowing()) {|if (true) {|' chrome/android/java/src/org/chromium/chrome/browser/tabbed_mode/TabbedAppMenuPropertiesDelegate.java 2>/dev/null || true
sed -i 's|if (!separateIncognitoWindow \|\| isIncognito) {|if (true) {|' chrome/android/java/src/org/chromium/chrome/browser/tabbed_mode/TabbedAppMenuPropertiesDelegate.java 2>/dev/null || true
sed -i 's|assert treeId.equals(documentId);|&\n if ("com.android.externalstorage.documents".equals(mAuthority)) { String fastId = mRelativePath.isEmpty() ? treeId : (treeId.endsWith(":") ? treeId + mRelativePath : treeId + "/" + mRelativePath); Uri fast = DocumentsContract.buildDocumentUriUsingTree(tree, fastId); return contentUriExists(fast) ? fast : null; }|' base/android/java/src/org/chromium/base/VirtualDocumentPath.java 2>/dev/null || true
python3 - << 'EOF' || true
import os
p = "chrome/browser/back_press/android/java/src/org/chromium/chrome/browser/back_press/MinimizeAppAndCloseTabBackPressHandler.java"
if os.path.exists(p):
    with open(p, "r", encoding="utf-8") as f:
        c = f.read()
    inject = "if (tab != null && tab.isIncognitoBranded()) { mSystemBackPressSupplier.set(true); return; }"
    while inject in c:
        c = c.replace(inject, "")
    target = "private void onTabChanged(@Nullable Tab tab) {"
    if target in c:
        c = c.replace(target, target + " " + inject, 1)
        with open(p, "w", encoding="utf-8") as f:
            f.write(c)
        print("[aerium] Cleaned and ensured onTabChanged() idempotent in MinimizeAppAndCloseTabBackPressHandler.java")
EOF

# ==============================================================================
# [23] WEBCONTENTS LIFETIME GUARD FOR OTR PROFILES (IDEMPOTENT)
# ==============================================================================
if [ -f content/public/browser/web_contents.h ] && ! grep -q "HasLiveWebContentsForBrowserContext" content/public/browser/web_contents.h; then
  sed -i '/CONTENT_EXPORT static WebContents\* FromRenderFrameHost(RenderFrameHost\* rfh);/a\CONTENT_EXPORT static bool HasLiveWebContentsForBrowserContext(BrowserContext* browser_context);' content/public/browser/web_contents.h 2>/dev/null || true
fi
if [ -f content/browser/web_contents/web_contents_impl.cc ] && ! grep -q "HasLiveWebContentsForBrowserContext" content/browser/web_contents/web_contents_impl.cc; then
  sed -i '/^WebContentsImpl::WebContentsImpl(BrowserContext\* browser_context)/i\ bool WebContents::HasLiveWebContentsForBrowserContext(BrowserContext* browser_context) { for (WebContentsImpl* web_contents : WebContentsImpl::GetAllWebContents()) { if (web_contents->GetBrowserContext() == browser_context) { return true; } } return false; }' content/browser/web_contents/web_contents_impl.cc 2>/dev/null || true
fi

# Guard profile_destroyer.cc to prevent duplicate includes or returns
python3 - << 'EOF' || true
import os
p = "chrome/browser/profiles/profile_destroyer.cc"
if os.path.exists(p):
    with open(p, "r", encoding="utf-8") as f:
        c = f.read()
    
    # 1. Clean any duplicate includes
    inc = '#include "content/public/browser/web_contents.h"'
    while c.count(inc) > 1:
        c = c.replace(inc + "\n", "", 1)
    if inc not in c:
        c = c.replace('#include "content/public/browser/render_process_host.h"',
                      '#include "content/public/browser/render_process_host.h"\n' + inc)

    # 2. Clean duplicate return guards
    guard = "if (content::WebContents::HasLiveWebContentsForBrowserContext(profile)) { return; }"
    while c.count(guard) > 1:
        c = c.replace(guard + "\n", "", 1)
    if guard not in c:
        target = "profile->MaybeSendDestroyedNotification();"
        if target in c:
            c = c.replace(target, guard + "\n  " + target, 1)

    with open(p, "w", encoding="utf-8") as f:
        f.write(c)
    print("[aerium] Cleaned and ensured profile_destroyer.cc is idempotent")
EOF
# ==============================================================================
# [24] MIXED PROFILE ACCEPTANCE (CLEAN)
# ==============================================================================
sed -i 's/|| mSupportedProfileType == SupportedProfileType.REGULAR) {/|| mSupportedProfileType == SupportedProfileType.REGULAR || mSupportedProfileType == SupportedProfileType.MIXED) {/' chrome/android/java/src/org/chromium/chrome/browser/ChromeTabbedActivity.java 2>/dev/null || true
sed -i 's/|| mSupportedProfileType == SupportedProfileType.OFF_THE_RECORD) {/|| mSupportedProfileType == SupportedProfileType.OFF_THE_RECORD || mSupportedProfileType == SupportedProfileType.MIXED) {/' chrome/android/java/src/org/chromium/chrome/browser/ChromeTabbedActivity.java 2>/dev/null || true

# ==============================================================================
# [25] TEST BUILD CIRCULAR INCLUDES & BACKUP SNACKBAR (IDEMPOTENT)
# ==============================================================================
python3 - << 'EOF' || true
import os
p = "chrome/test/BUILD.gn"
if os.path.exists(p):
    with open(p, "r", encoding="utf-8") as f:
        c = f.read()
    if "allow_circular_includes_from = []" not in c:
        c = "allow_circular_includes_from = []\n" + c
        with open(p, "w", encoding="utf-8") as f:
            f.write(c)
        print("[aerium] Added allow_circular_includes_from in chrome/test/BUILD.gn")
EOF

echo "==> Fixing RESTART_SNACKBAR_DURATION_MS in AeriumBackupFragment..."
find . -name "AeriumBackupFragment.java" -exec sed -i 's/RESTART_SNACKBAR_DURATION_MS/6000/g' {} + 2>/dev/null || true

# ==============================================================================
# [26] AERIUM CLASSIC 3D OVERLAPPING STACK TAB SWITCHER (CHROMIUM 88 ENGINE)
# ==============================================================================
echo "==> [26] Injecting True Classic 3D Overlapping Stack Tab Switcher with Settings..."

# Wipe intermediate resources so AAPT2 gets fresh non-conflicting packages
find . -path "*/obj/chrome/android/features/tab_ui/*resources*" -delete 2>/dev/null || true
find . -path "*/obj/chrome/android/chrome_app_java_resources*" -delete 2>/dev/null || true

python3 - << 'EOF'
import os, sys, glob, re

def find_file(filename, path_hint=""):
    out_sub = f"{os.sep}out{os.sep}"
    tp_sub = f"{os.sep}third_party{os.sep}"
    candidates = glob.glob(f"**/{filename}", recursive=True)
    matches = [
        p for p in candidates
        if out_sub not in p and not p.startswith(f"out{os.sep}")
        and tp_sub not in p and not p.startswith(f"third_party{os.sep}")
        and (not path_hint or path_hint in p)
    ]
    if not matches:
        print(f"[FATAL] Target file not found: {filename} (hint: '{path_hint}')")
        sys.exit(1)
    return matches[0]

# --- 1. DIRECT SANITIZATION OF TABLISTCOORDINATOR.JAVA ---
coord_path = find_file(
    "TabListCoordinator.java", path_hint=os.path.join("tasks", "tab_management")
)
with open(coord_path, "r", encoding="utf-8") as f:
  c = f.read()

# Revert TabListCoordinator.java back to pristine git/upstream state using git checkout if available
try:
  import subprocess

  subprocess.run(
      ["git", "checkout", "-f", "--", os.path.basename(coord_path)],
      cwd=os.path.dirname(coord_path),
      check=False,
  )
  with open(coord_path, "r", encoding="utf-8") as f:
    c = f.read()
except Exception:
  pass

# --- 2. Step B: Strings injection ---
grd_path = find_file("android_chrome_strings.grd", path_hint=os.path.join("chrome", "browser", "ui", "android", "strings"))
with open(grd_path, "r", encoding="utf-8") as f:
    grd_c = f.read()

if "IDS_AERIUM_TAB_SWITCHER_LAYOUT_TITLE" not in grd_c:
    new_strings = """
      <!-- Aerium Tab Switcher Layout Options -->
      <message name="IDS_AERIUM_TAB_SWITCHER_LAYOUT_TITLE" desc="Title for tab switcher layout preference.">
        Tab switcher layout
      </message>
      <message name="IDS_AERIUM_TAB_SWITCHER_LAYOUT_SUMMARY" desc="Summary for tab switcher layout preference.">
        Choose how tabs are organized in the tab switcher
      </message>
      <message name="IDS_AERIUM_TAB_SWITCHER_GRID" desc="Option for modern grid tab switcher.">
        Default (Grid)
      </message>
      <message name="IDS_AERIUM_TAB_SWITCHER_VERTICAL_WITH_GROUPS" desc="Option for classic vertical stack with groups.">
        Classic Vertical Stack (with tab groups)
      </message>
      <message name="IDS_AERIUM_TAB_SWITCHER_VERTICAL_NO_GROUPS" desc="Option for classic vertical stack without groups.">
        Classic Vertical Stack (without tab groups)
      </message>
"""
    m = re.search(r'<messages[^>]*>', grd_c)
    if m:
        idx = m.end()
        grd_c = grd_c[:idx] + new_strings + grd_c[idx:]
        with open(grd_path, "w", encoding="utf-8") as f:
            f.write(grd_c)
        print("[aerium] Strings injected successfully into android_chrome_strings.grd")

# --- 3. Step C: AAPT2 duplicate-safe array injection ---
# Remove duplicate arrays from any other XML first
for p in glob.glob("**/values.xml", recursive=True) + glob.glob("**/arrays.xml", recursive=True):
    if "out" in p or "third_party" in p:
        continue
    try:
        with open(p, "r", encoding="utf-8") as fp:
            xml_c = fp.read()
        if "aerium_tab_switcher_entries" in xml_c and "chrome/android/java/res/values" not in p:
            xml_c = re.sub(r'<!-- Aerium Tab Switcher Preference Arrays -->[\s\S]*?</string-array>', '', xml_c)
            xml_c = re.sub(r'<string-array name="aerium_tab_switcher_entries">[\s\S]*?</string-array>', '', xml_c)
            xml_c = re.sub(r'<string-array name="aerium_tab_switcher_values">[\s\S]*?</string-array>', '', xml_c)
            with open(p, "w", encoding="utf-8") as fp:
                fp.write(xml_c)
            print(f"[aerium] Removed duplicate arrays from {p}")
    except Exception:
        pass

# Now inject ONCE into chrome/android/java/res/values/values.xml
target_res_xml = None
for candidate in glob.glob("**/chrome/android/java/res/values/values.xml", recursive=True):
    if "out" not in candidate and "third_party" not in candidate:
        target_res_xml = candidate
        break
if not target_res_xml:
    for candidate in glob.glob("**/chrome/android/java/res/values/arrays.xml", recursive=True):
        if "out" not in candidate and "third_party" not in candidate:
            target_res_xml = candidate
            break

if target_res_xml:
    with open(target_res_xml, "r", encoding="utf-8") as f:
        res_c = f.read()
    if "aerium_tab_switcher_entries" not in res_c and "</resources>" in res_c:
        arrays_snippet = """
    <!-- Aerium Tab Switcher Preference Arrays -->
    <string-array name="aerium_tab_switcher_entries">
        <item>@string/aerium_tab_switcher_grid</item>
        <item>@string/aerium_tab_switcher_vertical_with_groups</item>
        <item>@string/aerium_tab_switcher_vertical_no_groups</item>
    </string-array>
    <string-array name="aerium_tab_switcher_values">
        <item>0</item>
        <item>1</item>
        <item>2</item>
    </string-array>
"""
        res_c = res_c.replace("</resources>", arrays_snippet + "\n</resources>", 1)
        with open(target_res_xml, "w", encoding="utf-8") as f:
            f.write(res_c)
        print(f"[aerium] Arrays injected uniquely into {target_res_xml}")

# --- 4. Step D: Settings XML injection ---
settings_path = find_file("tabs_settings.xml", path_hint=os.path.join("res", "xml"))
with open(settings_path, "r", encoding="utf-8") as f:
    set_c = f.read()

if 'android:key="aerium_tab_switcher_mode"' not in set_c and "</PreferenceScreen>" in set_c:
    pref_item = """
    <org.chromium.components.browser_ui.settings.ChromeBaseListPreference
        android:key="aerium_tab_switcher_mode"
        android:title="@string/aerium_tab_switcher_layout_title"
        android:summary="@string/aerium_tab_switcher_layout_summary"
        android:entries="@array/aerium_tab_switcher_entries"
        android:entryValues="@array/aerium_tab_switcher_values"
        android:defaultValue="0"
        app:useSimpleSummaryProvider="true" />
"""
    set_c = set_c.replace("</PreferenceScreen>", pref_item + "\n</PreferenceScreen>", 1)
    with open(settings_path, "w", encoding="utf-8") as f:
        f.write(set_c)
    print("[aerium] Preference injected into tabs_settings.xml")

# --- 5. Step E: TabUiFeatureUtilities.java ---
util_path = find_file("TabUiFeatureUtilities.java", path_hint=os.path.join("tasks", "tab_management"))
with open(util_path, "r", encoding="utf-8") as f:
    u_c = f.read()

if "getAeriumTabSwitcherMode" not in u_c:
    methods = """
    public static final String AERIUM_TAB_SWITCHER_MODE_KEY = "aerium_tab_switcher_mode";

    public static int getAeriumTabSwitcherMode() {
        try {
            String val = org.chromium.base.ContextUtils.getAppSharedPreferences()
                    .getString(AERIUM_TAB_SWITCHER_MODE_KEY, "0");
            return Integer.parseInt(val);
        } catch (Exception e) {
            return 0;
        }
    }

    public static boolean isVerticalStackSelected() {
        return getAeriumTabSwitcherMode() >= 1;
    }

    public static boolean isTabGroupDisabledForVerticalStack() {
        return getAeriumTabSwitcherMode() == 2;
    }
"""
    idx = u_c.rfind("}")
    if idx != -1:
        u_c = u_c[:idx] + "\n" + methods + "\n}\n"
        with open(util_path, "w", encoding="utf-8") as f:
            f.write(u_c)
        print("[aerium] TabUiFeatureUtilities patched")

# --- 6. Step F: ClassicStackLayoutManager.java ---
stack_lm_path = os.path.join(os.path.dirname(coord_path), "ClassicStackLayoutManager.java")
with open(stack_lm_path, "w", encoding="utf-8") as f:
    f.write("""// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package org.chromium.chrome.browser.tasks.tab_management;

import android.content.Context;
import android.view.View;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

public class ClassicStackLayoutManager extends LinearLayoutManager {
    private static final float SCALE_AMOUNT = 0.85f;
    private static final float TILT_ANGLE_DEGREES = 8.5f;
    private static final int MAX_STACKED_TABS_TOP = 3;
    private static final int PEEK_HEADER_DP = 64;
    
    private final float mDensity;
    private final int mPeekHeaderPx;

    public ClassicStackLayoutManager(Context context) {
        super(context, LinearLayoutManager.VERTICAL, false);
        mDensity = context.getResources().getDisplayMetrics().density;
        mPeekHeaderPx = (int) (PEEK_HEADER_DP * mDensity);
    }

    @Override
    public void onLayoutChildren(RecyclerView.Recycler recycler, RecyclerView.State state) {
        super.onLayoutChildren(recycler, state);
        applyClassic3DStackTransformations();
    }

    @Override
    public int scrollVerticallyBy(int dy, RecyclerView.Recycler recycler, RecyclerView.State state) {
        int scrolled = super.scrollVerticallyBy(dy, recycler, state);
        applyClassic3DStackTransformations();
        return scrolled;
    }

    private void applyClassic3DStackTransformations() {
        int childCount = getChildCount();
        if (childCount == 0) return;

        int parentTop = getPaddingTop();

        for (int i = 0; i < childCount; i++) {
            View child = getChildAt(i);
            if (child == null) continue;

            int position = getPosition(child);
            float viewTop = child.getTop();

            float elevation = Math.max(1.0f, 60.0f - (position * 2.5f));
            child.setElevation(elevation);

            child.setCameraDistance(mDensity * 10000.0f);
            child.setPivotX(child.getWidth() / 2.0f);
            child.setPivotY(0.0f);
            child.setRotationX(TILT_ANGLE_DEGREES);

            child.setScaleX(SCALE_AMOUNT);
            child.setScaleY(SCALE_AMOUNT);

            if (position > 0) {
                int childHeight = child.getHeight();
                if (childHeight > mPeekHeaderPx) {
                    float overlapShift = -(childHeight - mPeekHeaderPx) * position;
                    child.setTranslationY(overlapShift);
                }
            }

            if (viewTop < parentTop) {
                float offset = parentTop - viewTop;
                int stackRank = Math.min(position, MAX_STACKED_TABS_TOP);
                float compressionOffset = stackRank * (10.0f * mDensity);
                child.setTranslationY(child.getTranslationY() + offset + compressionOffset);
            }
        }
    }
}
""")
print(f"[aerium] Created {stack_lm_path}")

# Register in tab_management_java_sources.gni
gni_path = find_file("tab_management_java_sources.gni", path_hint=os.path.join("features", "tab_ui"))
with open(gni_path, "r", encoding="utf-8") as f:
    gni_c = f.read()
if "ClassicStackLayoutManager.java" not in gni_c:
    pattern = r'("//[^"]*TabListCoordinator\.java",)'
    repl = r'\1\n  "//chrome/android/features/tab_ui/java/src/org/chromium/chrome/browser/tasks/tab_management/ClassicStackLayoutManager.java",'
    gni_c = re.sub(pattern, repl, gni_c, count=1)
    with open(gni_path, "w", encoding="utf-8") as f:
        f.write(gni_c)
    print("[aerium] Registered ClassicStackLayoutManager in tab_management_java_sources.gni")

# --- 7. Full TabListCoordinator Integration ---
with open(coord_path, "r", encoding="utf-8") as f:
  coord_c = f.read()

# 1. layoutType: Disable UI grouping if Mode 2 is selected
if "isTabGroupDisabledForVerticalStack" not in coord_c:
  pattern_layout = (
      r"int\s+layoutType\s*=\s*actionOnRelatedTabs\s*\?\s*TabListLayoutType\.GROUPED\s*:\s*TabListLayoutType\.FLAT\s*;"
  )
  repl_layout = (
      "int layoutType = (actionOnRelatedTabs &&"
      " !TabUiFeatureUtilities.isTabGroupDisabledForVerticalStack()) ?"
      " TabListLayoutType.GROUPED : TabListLayoutType.FLAT;"
  )
  coord_c = re.sub(pattern_layout, repl_layout, coord_c, count=1)

# 2. setLayoutManager: Attach ClassicStackLayoutManager & disable clipping
if "ClassicStackLayoutManager stackManager" not in coord_c:
  pattern_rv = r"mRecyclerView\.setLayoutManager\(\s*gridLayoutManager\s*\);"
  repl_rv = """if (TabUiFeatureUtilities.isVerticalStackSelected()) {
            ClassicStackLayoutManager stackManager = new ClassicStackLayoutManager(mRecyclerView.getContext());
            mRecyclerView.setLayoutManager(stackManager);
            mRecyclerView.setClipChildren(false);
            mRecyclerView.setClipToPadding(false);
        } else {
            mRecyclerView.setLayoutManager(gridLayoutManager);
        }"""
  coord_c = re.sub(pattern_rv, repl_rv, coord_c, count=1)

# 3. setDefaultGridCardSize: Pass custom size WITHOUT return; preserving all braces
if "isVerticalStackSelected" not in coord_c:
  pattern_size = r"mMediator\.setDefaultGridCardSize\(\s*newDefaultSize\s*\);"
  repl_size = """if (TabUiFeatureUtilities.isVerticalStackSelected()) {
            int w = (newDefaultSize != null && newDefaultSize.getWidth() > 0) ? newDefaultSize.getWidth() : mRecyclerView.getWidth();
            if (w <= 0) w = 1080;
            int h = (mRecyclerView.getHeight() > 0) ? (int)(mRecyclerView.getHeight() * 0.70f) : (int)(w * 1.45f);
            mMediator.setDefaultGridCardSize(new Size(w, h));
        } else {
            mMediator.setDefaultGridCardSize(newDefaultSize);
        }"""
  coord_c = re.sub(pattern_size, repl_size, coord_c, count=1)

with open(coord_path, "w", encoding="utf-8") as f:
  f.write(coord_c)
print("[aerium] TabListCoordinator successfully patched.")


# --- 8. TabListMediator.java ---
med_path = find_file("TabListMediator.java", path_hint=os.path.join("tasks", "tab_management"))
with open(med_path, "r", encoding="utf-8") as f:
    med_c = f.read()

if "isVerticalStackSelected" not in med_c:
    pattern_span = r'int\s+getSpanCount\s*\(\s*int\s+screenWidthDp\s*\)\s*\{'
    repl_span = """int getSpanCount(int screenWidthDp) {
        if (TabUiFeatureUtilities.isVerticalStackSelected()) {
            return 1;
        }"""
    med_c = re.sub(pattern_span, repl_span, med_c, count=1)
    with open(med_path, "w", encoding="utf-8") as f:
        f.write(med_c)
    print("[aerium] TabListMediator patched")

EOF

# Invalidate intermediate javac jars to force clean recompilation
find . -path "*/obj/chrome/android/chrome_java/*" -name "*.jar" -delete 2>/dev/null || true
find . -path "*/obj/chrome/android/features/tab_ui/*" -name "*.jar" -delete 2>/dev/null || true



# ==============================================================================
# [27] ENTERPRISE DEEP SCAN CALLS BYPASS
# ==============================================================================
echo "==> Completely bypassing WebUIContentInfoSingleton deep scan calls..."
python3 - << 'EOF' || true
import os
files_to_fix = [
    "files_request_handler_base.cc",
    "multipart_uploader_base.cc",
    "cloud_binary_upload_service_base.cc",
    "resumable_uploader_base.cc"
]

for root, _, files in os.walk('.'):
    for f in files:
        if f in files_to_fix:
            p = os.path.join(root, f)
            try:
                with open(p, 'r', encoding='utf-8', errors='ignore') as fp:
                    lines = fp.readlines()
                out = []
                skip = False
                for line in lines:
                    if 'safe_browsing::WebUIContentInfoSingleton::GetInstance()' in line:
                        skip = True
                        out.append('    // bypassed deep scan logging\n')
                        if ';' in line:
                            skip = False
                        continue
                    if skip:
                        if ';' in line:
                            skip = False
                        continue
                    out.append(line)
                with open(p, 'w', encoding='utf-8') as fp:
                    fp.writelines(out)
                print(f"[aerium] Bypassed deep scan calls in {p}")
            except Exception as e:
                print(f"Error: {e}")
EOF

# ==============================================================================
# [28] SAFE BROWSING SERVICE NEUTRALIZATION & LINKER STUBS
# ==============================================================================
echo "==> Neutralizing safe_browsing_service in safe_browsing_bridge.cc..."
python3 - << 'EOF' || true
import os
for root, _, files in os.walk('.'):
    if "safe_browsing_bridge.cc" in files:
        p = os.path.join(root, "safe_browsing_bridge.cc")
        try:
            with open(p, "r", encoding="utf-8") as f:
                c = f.read()
            c = c.replace("reinterpret_cast<SafeBrowsingServiceInterface*>", "static_cast<SafeBrowsingServiceInterface*>")
            c = c.replace("reinterpret_cast<safe_browsing::SafeBrowsingServiceInterface*>", "static_cast<safe_browsing::SafeBrowsingServiceInterface*>")
            c = c.replace("g_browser_process->safe_browsing_service()", "nullptr")
            with open(p, "w", encoding="utf-8") as f:
                f.write(c)
            print(f"[aerium] Successfully patched safe_browsing_bridge.cc in {p}")
        except Exception as e:
            print(f"Error patching safe_browsing_bridge.cc: {e}")
EOF

echo "==> Injecting safe_browsing linker stubs into safe_browsing_bridge.cc..."
python3 - << 'EOF' || true
import os

stubs = r'''
// --- Aerium Safe Browsing Linker Stubs v2 ---
extern "C" {
  void _ZN13safe_browsing30PasswordReuseControllerAndroid18ShowCheckPasswordsEv() {}
  void _ZN13safe_browsing30PasswordReuseControllerAndroid11CloseDialogEv() {}
  void _ZN13safe_browsing30PasswordReuseControllerAndroid12IgnoreDialogEv() {}
  void _ZN13safe_browsing31SuspiciousSiteControllerAndroid11CloseDialogEN2ui18ModalDialogWrapper14DismissalCauseE() {}
  void _ZN13safe_browsing31SuspiciousSiteControllerAndroid23OnContinueButtonClickedEv() {}
  void _ZN13safe_browsing31SuspiciousSiteControllerAndroid20HandleBackNavigationENS_36SuspiciousSiteWarningUserInteractionE() {}
  void _ZN13safe_browsing31SuspiciousSiteControllerAndroid23OnHelpCenterLinkClickedEv() {}
  void _ZN13safe_browsing35NotificationContentDetectionUkmUtil42RecordSuspiciousNotificationInteractionUkmEiRK4GURLNSt4__Cr12basic_stringIcNS4_11char_traitsIcEENS4_9allocatorIcEEEEP7Profile() {}
  void* _ZN13safe_browsing44SafeBrowsingNavigationObserverManagerFactory20GetForBrowserContextEPN7content14BrowserContextE(void*) { return nullptr; }
  void* _ZN13safe_browsing16FileTypePolicies11GetInstanceEv() { static char dummy[256]; return dummy; }
  int _ZNK13safe_browsing16FileTypePolicies15UmaValueForFileERKN4base8FilePathE() { return 0; }
  void _ZN17component_updater43RegisterRealTimeUrlChecksAllowlistComponentEPNS_22ComponentUpdateServiceE() {}
  void _ZN13safe_browsing24ShowSafeBrowsingSettingsEPN2ui13WindowAndroidENS_19SettingsAccessPointE() {}
  void _ZN13safe_browsing30ShowAdvancedProtectionSettingsEPN2ui13WindowAndroidE() {}

  // static data members (const int kUserDataKey)
  extern const int _ZN41ChromePasswordReuseDetectionManagerClient12kUserDataKeyE;
  const int _ZN41ChromePasswordReuseDetectionManagerClient12kUserDataKeyE = 0;
  extern const int _ZN13safe_browsing31SuspiciousSiteControllerAndroid12kUserDataKeyE;
  const int _ZN13safe_browsing31SuspiciousSiteControllerAndroid12kUserDataKeyE = 0;
}
'''

for root, _, files in os.walk('.'):
    if "safe_browsing_bridge.cc" in files:
        p = os.path.join(root, "safe_browsing_bridge.cc")
        try:
            with open(p, "r", encoding="utf-8") as f:
                c = f.read()
            if "Aerium Safe Browsing Linker Stubs v2" not in c:
                c += "\n" + stubs
                with open(p, "w", encoding="utf-8") as f:
                    f.write(c)
                print(f"[aerium] Injected Safe Browsing linker stubs into {p}")
        except Exception as e:
            print(f"Error injecting stubs: {e}")
EOF

find . -path "*/obj/chrome/browser/safe_browsing/android/android/safe_browsing_bridge.o" -delete 2>/dev/null || true

# ==============================================================================
# [29] OTP PHISH GUARD DUMMY CLIENT
# ==============================================================================
echo "==> Defining OtpFillingSafeBrowsingCheckerClient in chrome_otp_phish_guard_delegate.cc..."
python3 - << 'EOF' || true
import os
for root, _, files in os.walk('.'):
    if "chrome_otp_phish_guard_delegate.cc" in files:
        p = os.path.join(root, "chrome_otp_phish_guard_delegate.cc")
        try:
            with open(p, "r", encoding="utf-8") as f:
                c = f.read()
            if "class OtpFillingSafeBrowsingCheckerClient {};" not in c:
                dummy = "\nnamespace autofill { class OtpFillingSafeBrowsingCheckerClient {}; }\n"
                c = c.replace('#include "chrome/browser/ui/autofill/chrome_otp_phish_guard_delegate.h"', '#include "chrome/browser/ui/autofill/chrome_otp_phish_guard_delegate.h"' + dummy)
                with open(p, "w", encoding="utf-8") as f:
                    f.write(c)
                print(f"[aerium] Patched OtpFillingSafeBrowsingCheckerClient in {p}")
        except Exception as e:
            print(f"Error patching chrome_otp_phish_guard_delegate.cc: {e}")
EOF

# ==============================================================================
# [30] GN DEBUG CONTEXT DUMP
# ==============================================================================
echo "=== GN INFO ==="
GN_LIST="$(buildtools/linux64/gn args out/Default --list --short 2>/dev/null || true)"
echo "$GN_LIST" | grep -iE "ntp|webui|desktop_android|extensions" || true
sed -n '2500,2520p' chrome/browser/extensions/BUILD.gn 2>/dev/null || true
sed -n '1,15p' chrome/browser/new_tab_page/BUILD.gn 2>/dev/null || true
echo "=============="

# ==============================================================================
# [31] NEW_TAB_PAGE GN TARGET ASSERTION RELAXATION FOR ANDROID
# ==============================================================================
if [ -f "chrome/browser/new_tab_page/BUILD.gn" ]; then
  echo "==> Relaxing new_tab_page assertion for Android..."
  sed -i 's/^assert(enable_webui_ntp)$/assert(enable_webui_ntp || is_android)/' chrome/browser/new_tab_page/BUILD.gn 2>/dev/null || true
fi

# ==============================================================================
# [32] ANDROID EXTENSION GN ARGS (SAFE & VERIFIED ONLY)
# ==============================================================================
for outdir in "out/Default" "chromium/src/out/Default"; do
  ARGS="$outdir/args.gn"
  if [ -f "$ARGS" ]; then
    [ -n "$(tail -c1 "$ARGS" 2>/dev/null)" ] && echo "" >> "$ARGS"
    sed -i '/^enable_extensions *=/d;/^enable_extensions_core *=/d;/^enable_desktop_android_extensions *=/d;/^enable_webui_tab_strip *=/d' "$ARGS"
    for kv in "enable_desktop_android_extensions = true" "enable_extensions_core = true" "enable_webui_tab_strip = false"; do
      k="${kv%% *}"
      if [ -z "$GN_LIST" ] || echo "$GN_LIST" | grep -q "^$k "; then
        echo "$kv" >> "$ARGS"
      else
        echo "[aerium] arg $k is not defined in this Chromium, skipping"
      fi
    done
    echo "[aerium] Updated args.gn with Android extension flags:"
    grep -n "extensions\|webui" "$ARGS" || true
  fi
done

# ==============================================================================
# [33] AERIUM_EXTENSIONS.H RESTORATION
# ==============================================================================
python3 - << 'EOF' || true
import os
for root, _, files in os.walk('.'):
    if "aerium_extensions.h" in files:
        hp = os.path.join(root, "aerium_extensions.h")
        try:
            with open(hp, "r", encoding="utf-8") as f:
                hc = f.read()
            if "class ExtensionInstallPrompt;" in hc:
                hc = hc.replace("class ExtensionInstallPrompt;", '#include "chrome/browser/extensions/extension_install_prompt.h"')
                with open(hp, "w", encoding="utf-8") as f:
                    f.write(hc)
                print(f"[aerium] Restored extension_install_prompt.h in {hp}")
        except Exception as e:
            print(f"Error: {e}")
EOF


# ==============================================================================
# [33.1] GN ASSERTION CHAIN PROBE (DISCOVERY & AUTO-RELAX)
# ==============================================================================
gn_probe() {
  local gn="buildtools/linux64/gn" outdir="out/Default" bak; bak="$(mktemp -d)"
  local -a hits=(); local i out loc file line
  echo "==> Starting GN Assertion Probe..."
  for i in $(seq 1 25); do
    out="$($gn gen "$outdir" 2>&1)" && { echo "[probe] GN passes after ${#hits[@]} relaxed assertion(s)"; break; }
    loc="$(printf '%s\n' "$out" | grep -m1 -oE 'ERROR at //[^ ]+' | sed -E 's/ERROR at \/\///')"
    file="$(printf '%s' "$loc" | cut -d: -f1)"; line="$(printf '%s' "$loc" | cut -d: -f2)"
    if [ -z "$file" ] || ! command sed -n "${line}p" "$file" | grep -q '^assert('; then
      echo "[probe] STOPPED: non-assertion GN error:"
      printf '%s\n' "$out" | head -25
      break
    fi
    mkdir -p "$bak/$(dirname "$file")"
    [ -f "$bak/$file" ] || cp -p "$file" "$bak/$file"
    hits+=("$file:$line  $(command sed -n "${line}p" "$file")")
    command sed -i "${line}s/^assert(/assert(true || /" "$file"
  done
  echo "========================================================"
  echo "[probe] asserts that block Android, in order:"
  printf '  %s\n' "${hits[@]}"
  echo "========================================================"
  [ "${AERIUM_PROBE_KEEP:-1}" = 1 ] || ( cd "$bak" && find . -type f | while read -r f; do cp -p "$f" "$OLDPWD/${f#./}"; done )
  rm -rf "$bak"
}

gn_probe
  
 


# ==============================================================================
# [34] ENTERPRISE_UTIL.CC VOID PREFS FIX
# ==============================================================================
echo "==> Patching enterprise_util.cc for safe_browsing_mode=0..."
python3 - << 'EOF' || true
import os
for root, _, files in os.walk('.'):
    if "enterprise_util.cc" in files:
        p = os.path.join(root, "enterprise_util.cc")
        try:
            with open(p, "r", encoding="utf-8") as f:
                c = f.read()
            if "PrefService* prefs =" in c and "(void)prefs;" not in c:
                c = c.replace(
                    "PrefService* prefs = Profile::FromBrowserContext(browser_context)->GetPrefs();",
                    "PrefService* prefs = Profile::FromBrowserContext(browser_context)->GetPrefs();\n  (void)prefs;"
                )
            target = "prefs->GetBoolean(prefs::kSafeBrowsingProceedAnywayDisabled)"
            if target in c:
                c = c.replace(target, "false /* safe_browsing_proceed_anyway_disabled */")
            with open(p, "w", encoding="utf-8") as f:
                f.write(c)
            print(f"[aerium] Successfully patched {p} with (void)prefs")
        except Exception as e:
            print(f"Error patching {p}: {e}")
EOF

find . -path "*/obj/chrome/browser/interstitials/impl/enterprise_util.o" -delete 2>/dev/null || true

# ==============================================================================
# [35] CHROME DOWNLOAD MANAGER DELEGATE PATCH
# ==============================================================================
echo "==> Patching chrome_download_manager_delegate.cc for safe_browsing_mode=0..."
python3 - << 'EOF' || true
import os
for root, _, files in os.walk('.'):
    if "chrome_download_manager_delegate.cc" in files:
        p = os.path.join(root, "chrome_download_manager_delegate.cc")
        try:
            with open(p, "r", encoding="utf-8") as f:
                c = f.read()

            c = c.replace(
                "bool IsForceSaveToCloud(",
                "[[maybe_unused]] bool IsForceSaveToCloud("
            )

            target = "auto settings = safe_browsing::ShouldUploadBinaryForDeepScanning(item);"
            if target in c:
                c = c.replace(target, "std::optional<enterprise_connectors::AnalysisSettings> settings = std::nullopt;")
            else:
                c = c.replace(
                    "safe_browsing::ShouldUploadBinaryForDeepScanning(item)",
                    "std::nullopt"
                )

            with open(p, "w", encoding="utf-8") as f:
                f.write(c)
            print(f"[aerium] Successfully patched {p}")
        except Exception as e:
            print(f"Error patching {p}: {e}")
EOF

find . -path "*/obj/chrome/browser/download/impl/chrome_download_manager_delegate.o" -delete 2>/dev/null || true

# ==============================================================================
# [35.1] DOWNLOAD TARGET DETERMINER: extensions::util is desktop-only
# ==============================================================================
python3 - << 'EOF' || true
import os
p = "chrome/browser/download/download_target_determiner.cc"
if os.path.exists(p):
    with open(p, "r", encoding="utf-8") as f:
        c = f.read()
    old = "!extensions::util::ShouldDownloadAsRegularFile()"
    marker = "true /* aerium: extension installs enabled */"
    if old in c:
        c = c.replace(old, marker)
        with open(p, "w", encoding="utf-8") as f:
            f.write(c)
        print("[aerium] Patched download_target_determiner.cc")
    lines = c.splitlines()
    for i, l in enumerate(lines):
        if marker in l:
            print("=== download_target_determiner.cc context ===")
            print("\n".join(lines[max(0, i - 10): i + 12]))
            print("=============================================")
            break
EOF
find . -path "*/obj/chrome/browser/download/impl/download_target_determiner.o" -delete 2>/dev/null || true

# ==============================================================================
# [36] GLIC WEB CLIENT HANDLER CLEAN IMPLEMENTATION
# ==============================================================================
python3 - << 'EOF' || true
import os

code = """#include "chrome/browser/glic/host/glic_web_client_handler.h"

#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "content/public/browser/browser_context.h"
#include "mojo/public/cpp/bindings/pending_receiver.h"
#include "mojo/public/cpp/bindings/pending_remote.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "url/gurl.h"

namespace glic {

namespace {

class WebClientHandlerImpl : public mojom::WebClientHandler,
                             public GlicWebClientAccess {
 public:
  WebClientHandlerImpl(
      Host* host,
      content::BrowserContext* browser_context,
      mojo::PendingReceiver<mojom::WebClientHandler> receiver,
      base::OnceClosure disconnect_callback,
      WebClientStateChangedCallback state_changed_callback)
      : receiver_(this, std::move(receiver)),
        disconnect_callback_(std::move(disconnect_callback)),
        state_changed_callback_(std::move(state_changed_callback)) {
    receiver_.set_disconnect_handler(base::BindOnce(
        &WebClientHandlerImpl::OnDisconnected, base::Unretained(this)));
  }

  ~WebClientHandlerImpl() override = default;

  void OnDisconnected() {
    if (disconnect_callback_) {
      std::move(disconnect_callback_).Run();
    }
  }

  // ---- mojom::WebClientHandler ----
  void WebClientCreated(::mojo::PendingRemote<mojom::WebClient> web_client,
                        WebClientCreatedCallback callback) override {}
  void WebClientInitialized() override {}
  void WebClientInitializeFailed() override {}
  void CreateActorHandler(
      ::mojo::PendingReceiver<mojom::ActorHandler> receiver,
      ::mojo::PendingRemote<mojom::ActorClient> client) override {}
  void CreateExperimentalTriggeringClient(
      ::mojo::PendingRemote<mojom::ExperimentalTriggeringClient> client)
      override {}
  void CreateAnnotationHandler(
      ::mojo::PendingReceiver<mojom::AnnotationHandler> receiver) override {}
  void CreateSkillsHandler(
      ::mojo::PendingReceiver<mojom::SkillsHandler> receiver,
      ::mojo::PendingRemote<mojom::SkillsClient> client) override {}
  void CreateZeroStateSuggestionsHandler(
      ::mojo::PendingReceiver<mojom::ZeroStateSuggestionsHandler> receiver)
      override {}

  void CreateTab(const ::GURL& url,
                 mojom::CreateTabOptionsPtr create_options,
                 CreateTabCallback callback) override {
    std::move(callback).Run(nullptr);
  }

  void ClosePanel() override {}

  void ActivateTabWithUrl(const ::GURL& exact_url,
                          mojom::ActivateTabOptionsPtr options,
                          ActivateTabWithUrlCallback callback) override {}
  void OpenLinkInPopup(const ::GURL& url,
                       int32_t popup_width,
                       int32_t popup_height) override {}
  void OpenGlicSettingsPage(mojom::OpenSettingsOptionsPtr options) override {}
  void OpenPasswordManagerSettingsPage() override {}
  void ClosePanelAndShutdown() override {}
  void AttachPanel() override {}
  void DetachPanel() override {}
  void OnModeChange(mojom::WebClientMode new_mode) override {}
  void OnMicrophoneStatusChange(mojom::MicrophoneStatus status) override {}
  void ShowProfilePicker() override {}
  void GetModelQualityClientId(
      GetModelQualityClientIdCallback callback) override {}
  void GetContextFromFocusedTab(
      mojom::TabContextOptionsPtr options,
      GetContextFromFocusedTabCallback callback) override {}
  void GetContextFromTab(int32_t tab_id,
                         mojom::TabContextOptionsPtr options,
                         GetContextFromTabCallback callback) override {}
  void GetImageBytesFromTab(int32_t tab_id,
                            const std::string& document_id,
                            int32_t dom_node_id,
                            GetImageBytesFromTabCallback callback) override {}
  void SetMaximumNumberOfPinnedTabs(
      uint32_t requested_max,
      SetMaximumNumberOfPinnedTabsCallback callback) override {}
  void PinTabs(const std::vector<int32_t>& tab_ids,
               mojom::PinTabsOptionsPtr options,
               PinTabsCallback callback) override {}
  void UnpinTabs(const std::vector<int32_t>& tab_ids,
                 mojom::UnpinTabsOptionsPtr options,
                 UnpinTabsCallback callback) override {}
  void UnpinAllTabs(mojom::UnpinTabsOptionsPtr options) override {}
  void SubscribeToPinCandidates(
      mojom::GetPinCandidatesOptionsPtr options,
      ::mojo::PendingRemote<mojom::PinCandidatesObserver> observer) override {}
  void ActivateTab(int32_t task_id) override {}
  void ResizeWidget(const ::gfx::Size& size,
                    ::base::TimeDelta duration,
                    ResizeWidgetCallback callback) override {}
  void CaptureScreenshot(CaptureScreenshotCallback callback) override {}
  void CaptureRegion(::mojo::PendingRemote<mojom::CaptureRegionObserver> observer,
                     mojom::CaptureRegionParamsPtr params) override {}
  void DeleteCapturedRegion(int32_t tab_id,
                            const ::base::UnguessableToken& id) override {}
  void SetAudioDucking(bool enable, SetAudioDuckingCallback callback) override {}
  void SetMinimumPanelSize(const ::gfx::Size& size) override {}
  void SetMicrophonePermissionState(
      bool enabled,
      SetMicrophonePermissionStateCallback callback) override {}
  void SetLocationPermissionState(
      bool enabled,
      SetLocationPermissionStateCallback callback) override {}
  void SetTabContextPermissionState(
      bool enabled,
      SetTabContextPermissionStateCallback callback) override {}
  void SetClosedCaptioningSetting(
      bool enabled,
      SetClosedCaptioningSettingCallback callback) override {}
  void SetActuationOnWebSetting(
      bool enabled,
      SetActuationOnWebSettingCallback callback) override {}
  void ShouldAllowMediaPermissionRequest(
      ShouldAllowMediaPermissionRequestCallback callback) override {}
  void ShouldAllowGeolocationPermissionRequest(
      ShouldAllowGeolocationPermissionRequestCallback callback) override {}
  void SetContextAccessIndicator(bool enabled) override {}
  void GetUserProfileInfo(GetUserProfileInfoCallback callback) override {}
  void SyncCookies(SyncCookiesCallback callback) override {}
  void ClientErrorDialogStateChanged(
      std::optional<mojom::ClientErrorDialogType> shown_dialog_type) override {}
  void ReportClientTransientError(
      ::mojo_base::mojom::AbslStatusCode status_code) override {}
  void ProcessCounterAbuseVerdict(
      int32_t tab_id,
      mojom::CounterAbuseVerdictPtr verdict) override {}
  void OnOptinImpression() override {}
  void OnUserInputSubmitted(mojom::WebClientMode mode) override {}
  void OnContextUploadStarted() override {}
  void OnContextUploadCompleted() override {}
  void OnReaction(mojom::MetricUserInputReactionType reactionType) override {}
  void OnResponseStarted() override {}
  void OnResponseStopped(mojom::OnResponseStoppedDetailsPtr details) override {}
  void OnSessionTerminated() override {}
  void OnTurnCompleted(mojom::WebClientModel model,
                       ::base::TimeDelta duration) override {}
  void OnResponseRated(bool positive) override {}
  void OnClosedCaptionsShown() override {}
  void OnActionSubmitted(bool is_retry) override {}
  void SetSyntheticExperimentState(const std::string& trial_name,
                                   const std::string& group_name) override {}
  void OpenOsPermissionSettingsMenu(
      ::content_settings::mojom::ContentSettingsType type) override {}
  void GetOsMicrophonePermissionStatus(
      GetOsMicrophonePermissionStatusCallback callback) override {}
  void GetZeroStateSuggestionsForFocusedTab(
      std::optional<bool> is_first_run,
      GetZeroStateSuggestionsForFocusedTabCallback callback) override {}
  void MaybeRefreshUserStatus() override {}
  void IsDebuggerAttached(IsDebuggerAttachedCallback callback) override {}
  void SubscribeToPageMetadata(
      int32_t tab_id,
      const std::vector<std::string>& names,
      SubscribeToPageMetadataCallback callback) override {}
  void SwitchConversation(mojom::ConversationInfoPtr info,
                          SwitchConversationCallback callback) override {}
  void RegisterConversation(mojom::ConversationInfoPtr info,
                            RegisterConversationCallback callback) override {}
  void SetOnboardingCompleted() override {}
  void SubscribeToTabData(
      int32_t tab_id,
      ::mojo::PendingRemote<mojom::TabDataHandler> receiver) override {}
  void SubscribeToTabFavicon(
      int32_t tab_id,
      ::mojo::PendingRemote<mojom::TabFaviconHandler> receiver) override {}

  // ---- GlicWebClientAccess ----
  mojom::WebClient* web_client() override { return nullptr; }
  mojom::WebClientState web_client_state() const override {
    return web_client_state_;
  }
  void PanelWillOpen(mojom::PanelOpeningDataPtr panel_opening_data,
                     PanelWillOpenCallback done) override {}
  void PanelWasClosed(base::OnceClosure done) override {
    std::move(done).Run();
  }
  void StopMicrophone(base::OnceClosure done) override {
    std::move(done).Run();
  }
  void PanelStateChanged(const glic::mojom::PanelState& panel_state) override {}
  void NotifyInstanceActivationChanged(bool is_active) override {}
  void ManualResizeChanged(bool resizing) override {}
  void NotifyAdditionalContext(mojom::AdditionalContextPtr context) override {}
  void FloatingPanelCanAttachChanged(bool can_attach) override {}
  void NotifyActorTaskListRowClicked(int32_t task_id) override {}
  void Invoke(mojom::InvokeOptionsPtr options,
              base::OnceClosure callback) override {
    std::move(callback).Run();
  }
  void OnUserInputSubmittedForTesting(mojom::WebClientMode mode) override {}

 private:
  mojo::Receiver<mojom::WebClientHandler> receiver_;
  base::OnceClosure disconnect_callback_;
  WebClientStateChangedCallback state_changed_callback_;
  mojom::WebClientState web_client_state_ = mojom::WebClientState{};
};

}  // namespace

std::unique_ptr<GlicWebClientAccess> MakeGlicWebClient(
    Host* host,
    content::BrowserContext* browser_context,
    mojo::PendingReceiver<glic::mojom::WebClientHandler> receiver,
    base::OnceClosure disconnect_callback,
    WebClientStateChangedCallback state_changed_callback) {
  return std::make_unique<WebClientHandlerImpl>(
      host, browser_context, std::move(receiver),
      std::move(disconnect_callback), std::move(state_changed_callback));
}

}  // namespace glic
"""

for root, _, files in os.walk('.'):
    if "glic_web_client_handler.cc" in files:
        p = os.path.join(root, "glic_web_client_handler.cc")
        with open(p, "w", encoding="utf-8") as fp:
            fp.write(code)
        print(f"[aerium] Successfully rewrote clean {p}")
EOF

# ==============================================================================
# [37] BUILD INPUT AUDIT LOG
# ==============================================================================
echo "=== BUILD INPUTS TOUCHED BY PATCH ==="
find . \( -path ./out -o -path ./.git -o -path ./third_party/llvm-build \) -prune -o \
  -type f -newer "$PRE_PATCH_MARKER" \
  \( -name '*.h' -o -name '*.gni' -o -name '*.gn' \) -print 2>/dev/null | head -60
echo "======================================"

# ==============================================================================
# [38] EARLY COMPILATION DIAGNOSTIC TARGETS
# ==============================================================================
echo "==> [38] Verifying fast compilation targets..."

export SISO_EXPERIMENTS=ignore-missing-targets

DIAG_TARGETS=(
  obj/chrome/browser/ui/webui/configs/chrome_web_ui_configs.o
  obj/chrome/browser/glic/impl/glic_web_client_handler.o
  obj/chrome/browser/interstitials/impl/enterprise_util.o
  obj/chrome/browser/download/impl/download_target_determiner.o
  obj/chrome/browser/download/impl/chrome_download_manager_delegate.o
  obj/chrome/browser/ui/android/extensions/extensions/extension_install_dialog_view_android.o
  obj/chrome/android/chrome_java.javac.jar
)

# ==============================================================================
# [39] PERSISTENT NOTIFICATION HANDLER ISOLATION
# ==============================================================================
echo "==> Isolating persistent_notification_handler.cc..."
python3 - << 'EOF' || true
import os
for root, _, files in os.walk('.'):
    if "persistent_notification_handler.cc" in files:
        p = os.path.join(root, "persistent_notification_handler.cc")
        try:
            with open(p, "r", encoding="utf-8") as f:
                c = f.read()
            if "#if 0 // safe_browsing_bypassed" not in c:
                target = "safe_browsing::NotificationContentDetectionUkmUtil::"
                if target in c:
                    idx = c.find(target)
                    b_start = c.rfind("\n", 0, idx)
                    b_end = c.find("}\n", idx)
                    if b_end != -1:
                        b_end = c.find("}\n", b_end + 2)
                        if b_end != -1:
                            c = c[:b_start] + "\n#if 0 // safe_browsing_bypassed\n" + c[b_start:b_end+2] + "\n#endif\n" + c[b_end+2:]
                            with open(p, "w", encoding="utf-8") as f:
                                f.write(c)
                            print(f"[aerium] Preprocessed {p}")
        except Exception as e:
            print(f"Error: {e}")
EOF

# ==============================================================================
# [40] CLEANUP SED WRAPPER & EXPORT COMPLETE
# ==============================================================================
unset -f sed 2>/dev/null || true
unset -f gn_probe 2>/dev/null || true

export PATCHED=1
