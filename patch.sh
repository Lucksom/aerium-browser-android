#!/bin/bash

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

# --- Unset Java options to prevent JVM printing to stderr
unset _JAVA_OPTIONS 2>/dev/null || true

# --- Add Extra 6GB Swapfile to safely handle final_dex / R8 memory without OOM
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

# --- Restore any files touched by previous runs and clean JNI cache
git checkout -- "net/*" "third_party/*" "components/*" 2>/dev/null || true

# --- Free Root Filesystem Disk Space
sudo rm -rf /usr/share/dotnet /opt/ghc /usr/local/lib/android /usr/local/share/boost /usr/local/share/powershell 2>/dev/null || true

# --- WebContents Context Duplicate Cleanup
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

# --- Launcher Icons and Graphics Setup
mkdir -p chrome/android/java/res_aerium_base/drawable chrome/android/java/res_aerium_base/mipmap-nodpi
cp $SCRIPT_DIR/res/drawable/themed_app_icon.xml chrome/android/java/res_aerium_base/drawable/themed_app_icon.xml 2>/dev/null || true
cp $SCRIPT_DIR/res/layered_app_icon_foreground.xml chrome/android/java/res_aerium_base/mipmap-nodpi/layered_app_icon_foreground.xml 2>/dev/null || true
for icon in $(find chrome/android/java/res_aerium_base -type f -name '*.png' 2>/dev/null); do $SCRIPT_DIR/res/icons.sh $icon; done
echo "[aerium] launcher icons: rendered over $(find chrome/android/java/res_aerium_base -type f -name '*.png' 2>/dev/null | wc -l) PNGs"

# --- AndroidManifest Native Libs Configuration
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

# --- Browser Rebranding Strings
sed -i 's|^\(\s*\)You and Google\s*$|\1Your browser|' chrome/browser/ui/android/strings/android_chrome_strings.grd 2>/dev/null || true

# --- Autofill Settings Menu Exclusion
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

# --- Incognito View Intent Routing
sed -i 's|if (!Intent\.ACTION_VIEW\.equals(intent\.getAction())) {|if (!Intent.ACTION_VIEW.equals(intent.getAction())\n                \|\| !android.webkit.URLUtil.isNetworkUrl(IntentHandler.getUrlFromIntent(intent))) {|' aerium/chromium_src/chrome/android/java/src/org/chromium/chrome/browser/LaunchIntentDispatcherHooks.java 2>/dev/null || true
sed -i 's|if (urlFromIntent == null) {|if (!android.webkit.URLUtil.isNetworkUrl(urlFromIntent)) {|' aerium/chromium_src/chrome/android/java/src/org/chromium/chrome/browser/LaunchIntentDispatcherHooks.java 2>/dev/null || true
sed -i 's|static Intent maybeModifyCustomTabIntents(Context context, Intent intent) {|static Intent maybeModifyCustomTabIntents(Context context, Intent intent) { if (!android.webkit.URLUtil.isNetworkUrl(IntentHandler.getUrlFromIntent(intent))) { return intent; }|' aerium/chromium_src/chrome/android/java/src/org/chromium/chrome/browser/LaunchIntentDispatcherHooks.java 2>/dev/null || true

# --- Remote Configuration Mechanism Guard
if [ -f aerium/android_config/parser/java/src/app/aerium/config/AeriumConfParser.java ] && ! grep -q "isEligible()" aerium/android_config/parser/java/src/app/aerium/config/AeriumConfParser.java; then
    sed -i 's|private static void init(Context ctx, SpecType specType) {|private static boolean isEligible() { return false; }\n\n    private static void init(Context ctx, SpecType specType) { if (!isEligible()) { return; }|' aerium/android_config/parser/java/src/app/aerium/config/AeriumConfParser.java 2>/dev/null || true
fi
sed -i 's|if (!_omit_dex) {|if (_is_base_module \&\& !_omit_dex) {|' build/config/android/rules.gni 2>/dev/null || true

# --- GPU and Rendering Baseline Features
sed -i '/feature_overrides.EnableFeature(::features::kSkipVulkanBlocklist);/d' chrome/browser/chrome_browser_field_trials.cc 2>/dev/null || true
sed -i '/feature_overrides.EnableFeature(::features::kDefaultANGLEVulkan);/d' chrome/browser/chrome_browser_field_trials.cc 2>/dev/null || true
sed -i '/feature_overrides.EnableFeature(::features::kVulkanFromANGLE);/d' chrome/browser/chrome_browser_field_trials.cc 2>/dev/null || true
sed -i '/feature_overrides.EnableFeature(::features::kDefaultPassthroughCommandDecoder);/d' chrome/browser/chrome_browser_field_trials.cc 2>/dev/null || true
sed -i '/BASE_FEATURE(kFallbackToSWIfGLES3NotSupported,/,/#endif/ s/base::FEATURE_ENABLED_BY_DEFAULT/base::FEATURE_DISABLED_BY_DEFAULT/' ui/gl/gl_features.cc 2>/dev/null || true

# --- Developer Tools and Clank Task Manager
sed -i 's/BASE_FEATURE(kSubmenusInAppMenu, base::FEATURE_DISABLED_BY_DEFAULT);/BASE_FEATURE(kSubmenusInAppMenu, base::FEATURE_ENABLED_BY_DEFAULT);/' chrome/browser/flags/android/chrome_feature_list.cc 2>/dev/null || true
sed -i '/BASE_FEATURE(kTaskManagerClank,/,/);/ s/base::FEATURE_DISABLED_BY_DEFAULT/base::FEATURE_ENABLED_BY_DEFAULT/' chrome/browser/task_manager/common/task_manager_features.cc 2>/dev/null || true
sed -i 's/BASE_FEATURE(kAndroidDevToolsFrontend, base::FEATURE_DISABLED_BY_DEFAULT);/BASE_FEATURE(kAndroidDevToolsFrontend, base::FEATURE_ENABLED_BY_DEFAULT);/' content/public/common/content_features.cc 2>/dev/null || true
sed -i 's:|| !DeviceFormFactor.isNonMultiDisplayContextOnTablet(mContext):|| false:' chrome/android/java/src/org/chromium/chrome/browser/tabbed_mode/MoreToolsItemBuilder.java 2>/dev/null || true
sed -i 's|boolean shouldShowDeveloperMenu() {|boolean shouldShowDeveloperMenu() { if (true) return DevToolsWindowAndroid.isDevToolsAllowedFor(getProfile(), mItemDelegate.getWebContents());|' chrome/android/java/src/org/chromium/chrome/browser/contextmenu/ChromeContextMenuPopulator.java 2>/dev/null || true
sed -i 's|TabUtils.isUsingDesktopUserAgent(mItemDelegate.getWebContents())|(true \|\| TabUtils.isUsingDesktopUserAgent(mItemDelegate.getWebContents()))|' chrome/android/java/src/org/chromium/chrome/browser/contextmenu/ChromeContextMenuPopulator.java 2>/dev/null || true

# --- Omnibox Site Search Feature
sed -i 's|BASE_FEATURE(kOmniboxSiteSearch, DISABLED);|BASE_FEATURE(kOmniboxSiteSearch, ENABLED);|' components/omnibox/common/omnibox_features.cc 2>/dev/null || true

# --- Desktop Media Playback Options
sed -i 's|#if BUILDFLAG(IS_ANDROID)|#if 0|' content/public/renderer/render_frame_media_playback_options.cc 2>/dev/null || true

# --- Extension Popup and Viewport Responsive Styles
sed -i 's|constexpr gfx::Size kMinSize = {25, 25};|constexpr gfx::Size kMinSize = {256, 25};|' chrome/browser/ui/android/extensions/extension_action_popup_contents.cc 2>/dev/null || true
sed -i 's|<meta name="color-scheme" content="light dark">|&\n<meta name="viewport" content="width=device-width">|' chrome/browser/resources/extensions/extensions.html 2>/dev/null || true
sed -i 's|--extensions-card-width: 400px;|--extensions-card-width: 96%;|' chrome/browser/resources/extensions/item_list.css 2>/dev/null || true
sed -i 's|--cr-toolbar-field-width: 680px;|--cr-toolbar-field-width: 96%;|' chrome/browser/resources/extensions/shared_vars.css 2>/dev/null || true
sed -i 's|padding: 24px 60px 64px;|padding: 24px 0 64px;|' chrome/browser/resources/extensions/item_list.css 2>/dev/null || true

# --- Manifest V2 Extension Support (Idempotent)
if [ -f "chrome/common/extensions/api/api_sources.gni" ]; then
  grep -q '"browser_action.json"' chrome/common/extensions/api/api_sources.gni || sed -i 's|uncompiled_sources_ = \[|&\n  "browser_action.json",\n  "page_action.json",|' chrome/common/extensions/api/api_sources.gni 2>/dev/null || true
fi
sed -i 's/api::webstore_private::MV2DeprecationStatus::kHardDisable)));/api::webstore_private::MV2DeprecationStatus::kNone)));/' extensions/browser/api/webstore_private/webstore_private_api.cc 2>/dev/null || true
sed -i 's/bool g_allow_mv2_for_testing = false;/bool g_allow_mv2_for_testing = true;/' extensions/browser/manifest_v2_handler.cc 2>/dev/null || true

# --- Off Store Extension Download Allowlist
sed -i '/^bool OffStoreInstallAllowedByPrefs(/a\  for (const char* d : {"addons.opera.com", "operacdn.com", "microsoftedge.microsoft.com", "edge.microsoft.com", "delivery.mp.microsoft.com", "github.com", "githubusercontent.com"}) if (item.GetURL().DomainIs(d) || item.GetReferrerUrl().DomainIs(d)) return true;' chrome/browser/download/download_crx_util.cc 2>/dev/null || true

# --- Legacy Extension Handler Policy
sed -i '/^bool ShouldDisableLegacyExtensions() {$/{N;N;N;N;N;N;s%bool ShouldDisableLegacyExtensions() {\n  if (g_allow_mv2_for_testing) {\n    // We allow legacy MV2 extensions for testing purposes.\n    return false;\n  }\n\n  return true;%bool ShouldDisableLegacyExtensions() {\n  // Aerium: Manifest V2 extensions stay loadable - see patch.sh.\n  return false;%}' extensions/browser/manifest_v2_handler.cc 2>/dev/null || true

# --- Phone Toolbar Extensions Container
sed -i '/<ViewStub/{N;N;N;N;N;N; /optional_button_stub/a\
        <ViewStub\
            android:id="@+id/extensions_toolbar_container_stub"\
            android:inflatedId="@+id/extensions_toolbar_container"\
            android:layout_width="wrap_content"\
            android:layout_height="match_parent" />
}' chrome/browser/ui/android/toolbar/java/res/layout/toolbar_phone.xml 2>/dev/null || true
sed -i 's|(ToolbarTablet) mToolbarLayout,|mToolbarLayout,|' chrome/android/java/src/org/chromium/chrome/browser/toolbar/ToolbarManager.java 2>/dev/null || true
sed -i '/\/\/ Draw the signin button if visible./i\        { View extContainer = findViewById(R.id.extensions_toolbar_container); if (extContainer != null \&\& extContainer.getVisibility() != View.GONE \&\& extContainer.getWidth() != 0) { canvas.save(); ViewUtils.translateCanvasToView(mToolbarButtonsContainer, extContainer, canvas); extContainer.draw(canvas); canvas.restore(); } }' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/top/ToolbarPhone.java 2>/dev/null || true

# --- Extension Action List Anchoring
sed -i '/public class RecyclerViewDelegate {$/a\public View getContainerView() { return mContainer; }' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/extensions/ExtensionActionListCoordinator.java 2>/dev/null || true
sed -i '/private void showPopupOnAnchor() {/,/private void closePopup() {/ s|if (buttonView == null) {|if (false) {|' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/extensions/ExtensionActionListMediator.java 2>/dev/null || true
sed -i 's|buttonView.setIsPressed(true);|if (buttonView != null) buttonView.setIsPressed(true);|' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/extensions/ExtensionActionListMediator.java 2>/dev/null || true
sed -i '/[[:space:]]mWindowAndroid,/!b;n;s|[[:space:]]buttonView,|buttonView != null ? buttonView : mRecyclerViewDelegate.getContainerView(),|' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/extensions/ExtensionActionListMediator.java 2>/dev/null || true

# --- Omnibox Android Desktop Matching Flag
sed -i 's/is_desktop_android = !!BUILDFLAG(IS_DESKTOP_ANDROID);/is_desktop_android = false;/' components/omnibox/browser/zero_suggest_verbatim_match_provider.cc 2>/dev/null || true
sed -i 's/is_android_mobile = is_android_any \&\& !is_android_desktop;/is_android_mobile = is_android_any \&\& is_android_desktop;/' components/omnibox/browser/autocomplete_result.cc 2>/dev/null || true

# --- Toolbar Pin Extensions Menu Control
sed -i '/Pref.PIN_EXTENSIONS_MENU_BUTTON, this::updateMenuButtonPinState);$/a\if (!mPrefService.getBoolean(Pref.PIN_EXTENSIONS_MENU_BUTTON)) { mContainer.findViewById(R.id.extensions_menu_button).setVisibility(View.GONE); }' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/extensions/ExtensionsToolbarCoordinatorImpl.java 2>/dev/null || true
sed -i '/"ExtensionsToolbarCoordinatorImpl.requestLayoutWithViewUtils()");$/a\if (!isMenuButtonPinned()) { mContainer.findViewById(R.id.extensions_menu_button).setVisibility(View.GONE); }' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/extensions/ExtensionsToolbarCoordinatorImpl.java 2>/dev/null || true

# --- Incognito Process and Window Separation
sed -i 's|if (!context->IsOffTheRecord()) {|if (true) {|' extensions/browser/process_manager.cc 2>/dev/null || true
sed -i 's|public static boolean shouldOpenIncognitoAsWindow() {|public static boolean shouldOpenIncognitoAsWindow() { if (org.chromium.chrome.browser.preferences.ChromeSharedPreferences.getInstance().readBoolean(org.chromium.chrome.browser.preferences.ChromePreferenceKeys.AERIUM_SEAMLESS_INCOGNITO, false)) { return false; } if (true) return true;|' chrome/browser/incognito/android/java/src/org/chromium/chrome/browser/incognito/IncognitoUtils.java 2>/dev/null || true

# --- Extension Host Process Priority
sed -i 's|host_contents_->SetColorProviderSource(NoOpColorProviderSource::Get());|&\nhost_contents_->SetPrimaryPageImportance(content::ChildProcessImportance::IMPORTANT, content::ChildProcessImportance::NORMAL);|' extensions/browser/extension_host.cc 2>/dev/null || true

# --- Extension Install Dialog Window Fallback
sed -i '/content::WebContents\* web_contents = show_params->GetParentWebContents();/,/DCHECK(view_android);/{/GetParentWebContents/!d}' chrome/browser/ui/android/extensions/extension_install_dialog_view_android.cc 2>/dev/null || true
sed -i 's|view_android->GetWindowAndroid();|show_params->GetParentWindow();|' chrome/browser/ui/android/extensions/extension_install_dialog_view_android.cc 2>/dev/null || true

# --- Touch Filtering Security Property Override
sed -i 's|.with(ModalDialogProperties.FILTER_TOUCH_FOR_SECURITY, true)|.with(ModalDialogProperties.FILTER_TOUCH_FOR_SECURITY, false)|' chrome/browser/ui/android/extensions/java/src/org/chromium/chrome/browser/ui/extensions/ExtensionInstallDialogBridge.java 2>/dev/null || true

# --- Virtual Document Path and Content URI Locales
sed -i 's|while (!(locale_path = locales.Next()).empty()) {|&if (locale_path.IsContentUri()) { locale_path = path.Append(locales.GetInfo().GetName()); }|' extensions/common/manifest_handlers/default_locale_handler.cc 2>/dev/null || true
sed -i 's|while (!(locale_folder = locales.Next()).empty()) {|&if (locale_folder.IsContentUri()) { locale_folder = locale_path.Append(locales.GetInfo().GetName()); }|' extensions/common/extension_l10n_util.cc 2>/dev/null || true
sed -i '/extension_l10n_util::ValidateExtensionLocales($/,/error) &&$/{s|extension_l10n_util::ValidateExtensionLocales(|(extension_path_.IsVirtualDocumentPath() \|\| &|;s|error) &&|error)) \&\&|}' extensions/browser/unpacked_installer.cc 2>/dev/null || true

# --- App Menu Incognito Display
sed -i 's|if (!IncognitoUtils.shouldOpenIncognitoAsWindow() \|\| isIncognitoShowing()) {|if (true) {|' chrome/android/java/src/org/chromium/chrome/browser/tabbed_mode/TabbedAppMenuPropertiesDelegate.java 2>/dev/null || true
sed -i 's|if (!separateIncognitoWindow \|\| isIncognito) {|if (true) {|' chrome/android/java/src/org/chromium/chrome/browser/tabbed_mode/TabbedAppMenuPropertiesDelegate.java 2>/dev/null || true

# --- Document URI Tree Path Fast Resolver
sed -i 's|assert treeId.equals(documentId);|&\n if ("com.android.externalstorage.documents".equals(mAuthority)) { String fastId = mRelativePath.isEmpty() ? treeId : (treeId.endsWith(":") ? treeId + mRelativePath : treeId + "/" + mRelativePath); Uri fast = DocumentsContract.buildDocumentUriUsingTree(tree, fastId); return contentUriExists(fast) ? fast : null; }|' base/android/java/src/org/chromium/base/VirtualDocumentPath.java 2>/dev/null || true

# --- Back Press Handling for Incognito Tabs
sed -i 's|private void onTabChanged(@Nullable Tab tab) {|private void onTabChanged(@Nullable Tab tab) { if (tab != null \&\& tab.isIncognitoBranded()) { mSystemBackPressSupplier.set(true); return; }|' chrome/browser/back_press/android/java/src/org/chromium/chrome/browser/back_press/MinimizeAppAndCloseTabBackPressHandler.java 2>/dev/null || true

# --- Tabs API Null Pointer Guard
sed -i '/for (int i = 0; i < tab_list->GetTabCount(); ++i) {/i if (!tab_list) { continue; }' chrome/browser/extensions/api/tabs/tabs_api.cc 2>/dev/null || true

# --- WebContents Lifetime Guard for OTR Profiles
if [ -f content/public/browser/web_contents.h ] && ! grep -q "HasLiveWebContentsForBrowserContext" content/public/browser/web_contents.h; then
  sed -i '/CONTENT_EXPORT static WebContents\* FromRenderFrameHost(RenderFrameHost\* rfh);/a\CONTENT_EXPORT static bool HasLiveWebContentsForBrowserContext(BrowserContext* browser_context);' content/public/browser/web_contents.h 2>/dev/null || true
fi
if [ -f content/browser/web_contents/web_contents_impl.cc ] && ! grep -q "HasLiveWebContentsForBrowserContext" content/browser/web_contents/web_contents_impl.cc; then
  sed -i '/^WebContentsImpl::WebContentsImpl(BrowserContext\* browser_context)/i\ bool WebContents::HasLiveWebContentsForBrowserContext(BrowserContext* browser_context) { for (WebContentsImpl* web_contents : WebContentsImpl::GetAllWebContents()) { if (web_contents->GetBrowserContext() == browser_context) { return true; } } return false; }' content/browser/web_contents/web_contents_impl.cc 2>/dev/null || true
fi
sed -i '/#include "content\/public\/browser\/render_process_host.h"/a#include "content/public/browser/web_contents.h"' chrome/browser/profiles/profile_destroyer.cc 2>/dev/null || true
sed -i '/^void ProfileDestroyer::DestroyOTRProfileWhenAppropriateWithTimeout($/,/MaybeSendDestroyedNotification/{/  profile->MaybeSendDestroyedNotification();/i\
if (content::WebContents::HasLiveWebContentsForBrowserContext(profile)) { return; }
}' chrome/browser/profiles/profile_destroyer.cc 2>/dev/null || true

# --- Mixed Profile Activity Acceptance
sed -i 's/|| mSupportedProfileType == SupportedProfileType.REGULAR) {/|| mSupportedProfileType == SupportedProfileType.REGULAR || mSupportedProfileType == SupportedProfileType.MIXED) {/' chrome/android/java/src/org/chromium/chrome/browser/ChromeTabbedActivity.java 2>/dev/null || true
sed -i 's/|| mSupportedProfileType == SupportedProfileType.OFF_THE_RECORD) {/|| mSupportedProfileType == SupportedProfileType.OFF_THE_RECORD || mSupportedProfileType == SupportedProfileType.MIXED) {/' chrome/android/java/src/org/chromium/chrome/browser/ChromeTabbedActivity.java 2>/dev/null || true

# --- Tab Group Feature Auto Creation Crash Prevention
if [ -d "chrome/android" ] || [ -d "src/chrome/android" ]; then
  echo "==> Hooking TabGroupFeatureUtils to prevent auto-creation crashes..."
  python3 - << 'EOF' || true
import os
target_dirs = [d for d in ["chrome/android", "src/chrome/android"] if os.path.isdir(d)]
for base in target_dirs:
    for root, dirs, files in os.walk(base):
        for f in files:
            if f == "TabGroupFeatureUtils.java":
                path = os.path.join(root, f)
                try:
                    with open(path, "r", encoding="utf-8", errors="ignore") as fp:
                        content = fp.read()
                    if "isTabGroupAutoCreationEnabled()" in content and "return false;" not in content:
                        replaced = content.replace(
                            "public static boolean isTabGroupAutoCreationEnabled() {",
                            "public static boolean isTabGroupAutoCreationEnabled() {\n        return false;"
                        )
                        with open(path, "w", encoding="utf-8") as fp:
                            fp.write(replaced)
                        print(f"Patched: {path}")
                except Exception:
                    pass
EOF
fi

# --- Test Build Circular Includes Fix (Idempotent)
if [ -f "chrome/test/BUILD.gn" ]; then
  echo "==> Fixing allow_circular_includes_from in chrome/test/BUILD.gn..."
  grep -q '^allow_circular_includes_from' chrome/test/BUILD.gn || sed -i '1s/^/allow_circular_includes_from = []\n/' chrome/test/BUILD.gn 2>/dev/null || true
fi

# --- Backup Fragment Snackbar Duration Definition
echo "==> Fixing RESTART_SNACKBAR_DURATION_MS in AeriumBackupFragment..."
find . -name "AeriumBackupFragment.java" -exec sed -i 's/RESTART_SNACKBAR_DURATION_MS/6000/g' {} + 2>/dev/null || true

# --- Complete Vertical Tab Switcher (Kiwi-style 3D Stack) Setup
echo "==> Setting up Complete Vertical Tab Switcher..."
python3 - << 'EOF' || true
import os, re

# 1. ChromePreferenceKeys.java
pref_path = "chrome/browser/preferences/android/java/src/org/chromium/chrome/browser/preferences/ChromePreferenceKeys.java"
if os.path.exists(pref_path):
    with open(pref_path, "r") as f:
        c = f.read()
    if "TAB_SWITCHER_TYPE" not in c:
        idx = c.rfind("}")
        if idx != -1:
            injection = "\n    public static final String TAB_SWITCHER_TYPE = \"Chrome.Tabs.TabSwitcherType\";\n    public static final int TAB_SWITCHER_TYPE_GRID_GROUPS = 0;\n    public static final int TAB_SWITCHER_TYPE_VERTICAL_STACK = 1;\n}\n"
            c = c[:idx] + injection
            with open(pref_path, "w") as f:
                f.write(c)
            print("[aerium] Patched ChromePreferenceKeys.java")

# 2. TabUiFeatureUtilities.java
tabui_path = "chrome/android/java/src/org/chromium/chrome/browser/tasks/tab_management/TabUiFeatureUtilities.java"
if os.path.exists(tabui_path):
    with open(tabui_path, "r") as f:
        c = f.read()
    if "isStackTabSwitcherSelected" not in c:
        methods = """
    public static boolean isStackTabSwitcherSelected() {
        return ChromeSharedPreferences.getInstance().readInt(
                ChromePreferenceKeys.TAB_SWITCHER_TYPE,
                ChromePreferenceKeys.TAB_SWITCHER_TYPE_GRID_GROUPS)
                == ChromePreferenceKeys.TAB_SWITCHER_TYPE_VERTICAL_STACK;
    }

    public static int getSelectedTabSwitcherType() {
        return ChromeSharedPreferences.getInstance().readInt(
                ChromePreferenceKeys.TAB_SWITCHER_TYPE,
                ChromePreferenceKeys.TAB_SWITCHER_TYPE_GRID_GROUPS);
    }
"""
        target = "public class TabUiFeatureUtilities {"
        if target in c:
            c = c.replace(target, target + methods, 1)
            c = c.replace("public static boolean isTabGroupsAndroidEnabled() {", "public static boolean isTabGroupsAndroidEnabled() {\n        if (isStackTabSwitcherSelected()) { return false; }")
            with open(tabui_path, "w") as f:
                f.write(c)
            print("[aerium] Patched TabUiFeatureUtilities.java")

# 3. TabModelFilterProvider.java (Defensively placed after package)
filter_path = "chrome/android/java/src/org/chromium/chrome/browser/tabmodel/TabModelFilterProvider.java"
target_filter = "public TabModelFilter getTabModelFilter(boolean isIncognito) {"
if os.path.exists(tabui_path) and os.path.exists(filter_path):
    with open(filter_path, "r") as f:
        c = f.read()
    if ("isStackTabSwitcherSelected" not in c and target_filter in c
            and "mEmptyNormalTabModelFilter" in c and "mEmptyIncognitoTabModelFilter" in c):
        c = re.sub(r'(^package [^;]+;\n)',
                   r'\1\nimport org.chromium.chrome.browser.tasks.tab_management.TabUiFeatureUtilities;\n',
                   c, count=1, flags=re.M)
        c = c.replace(target_filter, target_filter + "\n        if (TabUiFeatureUtilities.isStackTabSwitcherSelected()) {\n            return isIncognito ? mEmptyIncognitoTabModelFilter : mEmptyNormalTabModelFilter;\n        }", 1)
        with open(filter_path, "w") as f:
            f.write(c)
        print("[aerium] Patched TabModelFilterProvider.java")

# 4. tabs_settings_preferences.xml
xml_path = "chrome/android/java/res/xml/tabs_settings_preferences.xml"
if os.path.exists(xml_path):
    with open(xml_path, "r") as f:
        c = f.read()
    if "tab_switcher_type" not in c:
        cat = """
    <PreferenceCategory
        android:title="@string/tab_switcher_category_title">
        <ListPreference
            android:key="tab_switcher_type"
            android:title="@string/tab_switcher_type_title"
            android:entries="@array/tab_switcher_type_entries"
            android:entryValues="@array/tab_switcher_type_values"
            android:defaultValue="0" />
    </PreferenceCategory>
"""
        c = c.replace("android:title=\"@string/tabs_settings_title\">", "android:title=\"@string/tabs_settings_title\">" + cat, 1)
        with open(xml_path, "w") as f:
            f.write(c)
        print("[aerium] Patched tabs_settings_preferences.xml")

# 5. arrays.xml
arr_path = "chrome/android/java/res/values/arrays.xml"
if os.path.exists(arr_path):
    with open(arr_path, "r") as f:
        c = f.read()
    if "tab_switcher_type_entries" not in c:
        arrs = """
    <string-array name="tab_switcher_type_entries">
        <item>@string/tab_switcher_option_tab_group</item>
        <item>@string/tab_switcher_option_vertical_stack</item>
    </string-array>
    <string-array name="tab_switcher_type_values">
        <item>0</item>
        <item>1</item>
    </string-array>
"""
        idx = c.rfind("</resources>")
        if idx != -1:
            c = c[:idx] + arrs + "\n</resources>\n"
            with open(arr_path, "w") as f:
                f.write(c)
            print("[aerium] Patched arrays.xml")

# 6. android_chrome_strings.grd (Clean, no duplicate strings)
grd_path = "chrome/browser/ui/android/strings/android_chrome_strings.grd"
if os.path.exists(grd_path):
    with open(grd_path, "r") as f:
        c = f.read()
    if "IDS_TAB_SWITCHER_TYPE_TITLE" not in c:
        msgs = """
      <message name="IDS_TAB_SWITCHER_CATEGORY_TITLE" desc="Title for tab switcher category">
        Tab Switcher
      </message>
      <message name="IDS_TAB_SWITCHER_TYPE_TITLE" desc="Title for tab switcher type">
        Tab switcher layout
      </message>
      <message name="IDS_TAB_SWITCHER_OPTION_TAB_GROUP" desc="Label for tab group option">
        Tab group (Default grid)
      </message>
      <message name="IDS_TAB_SWITCHER_OPTION_VERTICAL_STACK" desc="Label for vertical stack option">
        Vertical stack tab switcher
      </message>
      <message name="IDS_TAB_SWITCHER_RESTART_TITLE" desc="Title of restart dialog">
        Relaunch Aerium
      </message>
      <message name="IDS_TAB_SWITCHER_RESTART_MESSAGE" desc="Message indicating Aerium needs to restart">
        Aerium needs to be relaunched to apply the new tab switcher layout.
      </message>
"""
        if "IDS_RELAUNCH_NOW" not in c:
            msgs += """      <message name="IDS_RELAUNCH_NOW" desc="Action to restart immediately">
        Relaunch now
      </message>
"""
        if "IDS_LATER" not in c:
            msgs += """      <message name="IDS_LATER" desc="Action to restart later">
        Later
      </message>
"""
        idx = c.rfind("</messages>")
        if idx != -1:
            c = c[:idx] + msgs + "\n    </messages>" + c[idx+11:]
            with open(grd_path, "w") as f:
                f.write(c)
            print("[aerium] Patched android_chrome_strings.grd")

# 7. TabsSettingsFragment.java
frag_path = "chrome/android/java/src/org/chromium/chrome/browser/settings/TabsSettingsFragment.java"
if os.path.exists(frag_path):
    with open(frag_path, "r") as f:
        c = f.read()
    if "PREF_TAB_SWITCHER_TYPE" not in c:
        imports = """
import androidx.appcompat.app.AlertDialog;
import androidx.preference.ListPreference;
import org.chromium.chrome.browser.preferences.ChromePreferenceKeys;
import org.chromium.chrome.browser.preferences.ChromeSharedPreferences;
import org.chromium.chrome.browser.tasks.tab_management.TabUiFeatureUtilities;
"""
        c = c.replace("import androidx.preference.PreferenceFragmentCompat;", "import androidx.preference.PreferenceFragmentCompat;\n" + imports)
        c = c.replace("implements Preference.OnPreferenceChangeListener {", """implements Preference.OnPreferenceChangeListener {
    public static final String PREF_TAB_SWITCHER_TYPE = "tab_switcher_type";
    private ListPreference mTabSwitcherPreference;
""")
        hook_init = """
        mTabSwitcherPreference = (ListPreference) findPreference(PREF_TAB_SWITCHER_TYPE);
        if (mTabSwitcherPreference != null) {
            int currentType = TabUiFeatureUtilities.getSelectedTabSwitcherType();
            mTabSwitcherPreference.setValue(String.valueOf(currentType));
            mTabSwitcherPreference.setOnPreferenceChangeListener(this);
        }
"""
        c = c.replace("getActivity().setTitle(R.string.tabs_settings_title);", "getActivity().setTitle(R.string.tabs_settings_title);\n" + hook_init)
        
        pref_change = """
        if (PREF_TAB_SWITCHER_TYPE.equals(preference.getKey())) {
            int newType = Integer.parseInt((String) newValue);
            ChromeSharedPreferences.getInstance().writeInt(
                    ChromePreferenceKeys.TAB_SWITCHER_TYPE, newType);
            if (getActivity() != null) {
                new AlertDialog.Builder(getActivity())
                        .setTitle(R.string.tab_switcher_restart_title)
                        .setMessage(R.string.tab_switcher_restart_message)
                        .setPositiveButton(R.string.relaunch_now, (dialog, which) -> {
                            getActivity().finishAffinity();
                            System.exit(0);
                        })
                        .setNegativeButton(R.string.later, null)
                        .show();
            }
            return true;
        }
"""
        c = c.replace("public boolean onPreferenceChange(Preference preference, Object newValue) {", "public boolean onPreferenceChange(Preference preference, Object newValue) {\n" + pref_change)
        with open(frag_path, "w") as f:
            f.write(c)
        print("[aerium] Patched TabsSettingsFragment.java")
EOF

# --- Enterprise Cloud Content Scanning Deep Scan Bypass
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

# --- Safe Browsing Bridge Service Neutralization
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
            c = g_browser_process = c.replace("g_browser_process->safe_browsing_service()", "nullptr")
            with open(p, "w", encoding="utf-8") as f:
                f.write(c)
            print(f"[aerium] Successfully patched safe_browsing_bridge.cc in {p}")
        except Exception as e:
            print(f"Error patching safe_browsing_bridge.cc: {e}")
EOF

# --- Inject Safe Browsing linker stubs into safe_browsing_bridge.cc (safe_browsing_mode=0)
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

# --- Chrome OTP Phish Guard Checker Client Dummy Class
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

# --- Enable extensions on Android (Desktop Android on Clank - safe flags)
for outdir in "out/Default" "chromium/src/out/Default"; do
  ARGS="$outdir/args.gn"
  if [ -f "$ARGS" ]; then
    [ -n "$(tail -c1 "$ARGS" 2>/dev/null)" ] && echo "" >> "$ARGS"
    sed -i '/^enable_extensions *=/d;/^enable_extensions_core *=/d;/^enable_desktop_android_extensions *=/d' "$ARGS"
    { echo "enable_desktop_android_extensions = true"; echo "enable_extensions_core = true"; } >> "$ARGS"
    echo "[aerium] Updated args.gn with Android extension flags:"
    grep -n "extensions" "$ARGS" || true
  fi
done

# --- Ensure aerium_extensions.h include is clean
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

# --- Fix enterprise_util.cc when safe_browsing_mode = 0
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

# --- Fix chrome_download_manager_delegate.cc for safe_browsing_mode=0
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

# --- glic_web_client_handler Clean Implementation
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

echo "=== BUILD INPUTS TOUCHED BY PATCH ==="
find . \( -path ./out -o -path ./.git -o -path ./third_party/llvm-build \) -prune -o \
  -type f -newer "$PRE_PATCH_MARKER" \
  \( -name '*.h' -o -name '*.gni' -o -name '*.gn' \) -print 2>/dev/null | head -60
echo "======================================"

# --- Early Compilation Diagnostic for WebUI Configs, GLIC Handler, and Enterprise Util
for outdir in "out/Default" "chromium/src/out/Default"; do
  if [ -f "$outdir/build.ninja" ]; then
    echo "==> Running early compilation diagnostic in $outdir..."
    export PATH="$PATH:$GITHUB_WORKSPACE/chromium/depot_tools:$GITHUB_WORKSPACE/depot_tools"
    AUTONINJA_BIN=$(which autoninja 2>/dev/null || find . -name "autoninja" | head -n 1)
    if [ -n "$AUTONINJA_BIN" ]; then
      bash "$AUTONINJA_BIN" -C "$outdir" \
        obj/chrome/browser/ui/webui/configs/chrome_web_ui_configs.o \
        obj/chrome/browser/glic/impl/glic_web_client_handler.o \
        obj/chrome/browser/interstitials/impl/enterprise_util.o \
        obj/chrome/browser/download/impl/download_target_determiner.o \
        obj/chrome/browser/download/impl/chrome_download_manager_delegate.o || {
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "[aerium] Diagnostic failed: one or more targets failed to compile."
        echo "Aborting early to prevent waiting through the full build queue."
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        exit 1
      }
      echo "==> [SUCCESS] All diagnostic targets compiled successfully!"
    fi
    break
  fi
done

# --- Persistent Notification Handler Preprocessor Isolation
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

# Clean up sed wrapper so build.sh uses standard system sed
unset -f sed

export PATCHED=1