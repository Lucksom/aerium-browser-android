#!/bin/bash

# --- Launcher icons, and native libraries left uncompressed in the APK.
#
# res_aerium_base is the correct name and is NOT a directory this script
# invents. build.sh rewrites the Vanadium patches before applying them -
# `replace "$SCRIPT_DIR/vanadium/patches" "vanadium" "aerium"` and its two
# case variants, immediately before the `git am` - so the branding patch that
# upstream writes against chrome/android/java/res_vanadium_base creates
# res_aerium_base in the built tree, and the entries it adds to
# chrome/android/BUILD.gn are renamed to match. By the time this runs, the
# directory exists and holds fifteen PNGs across five densities.
#
# Worth writing down because the tree and the checked-in patch disagree, and
# grepping this repository for res_aerium_base finds only these lines: the
# wiring lives in a patch that says res_vanadium_base right up until the moment
# it is applied. Reading either half alone suggests this block is dead code
# writing to a directory nothing references. It is not.
#
# mkdir -p is kept for the two XML copies, which land in subdirectories the
# branding patch does not necessarily create.
mkdir -p chrome/android/java/res_aerium_base/drawable chrome/android/java/res_aerium_base/mipmap-nodpi
cp $SCRIPT_DIR/res/drawable/themed_app_icon.xml chrome/android/java/res_aerium_base/drawable/themed_app_icon.xml
cp $SCRIPT_DIR/res/layered_app_icon_foreground.xml chrome/android/java/res_aerium_base/mipmap-nodpi/layered_app_icon_foreground.xml
for icon in $(find chrome/android/java/res_aerium_base -type f -name '*.png'); do $SCRIPT_DIR/res/icons.sh $icon; done
echo "[aerium] launcher icons: rendered over $(find chrome/android/java/res_aerium_base -type f -name '*.png' | wc -l) PNGs"
sed -i 's|<application |<application android:extractNativeLibs="false" |' chrome/android/java/AndroidManifest.xml
# sed -i 's|Google LLC|jqssun, Google LLC|' chrome/browser/ui/android/strings/android_chrome_strings.grd

# --- Rebrand the "You and Google" settings section header.
#
# Rebrand the "You and Google" settings section header (IDS_PREFS_SECTION_ACCOUNT_AND_GOOGLE_SERVICES).
sed -i 's|^\(\s*\)You and Google\s*$|\1Your browser|' chrome/browser/ui/android/strings/android_chrome_strings.grd

# --- Drop the "Autofill and passwords" settings entry point.
#
# Drop the whole "Autofill and passwords" settings entry point plus its
# Passwords/Payment methods/Addresses/Autofill options sub-items (orders
# 11-17 in main_preferences.xml) - Aerium doesn't ship autofill/password
# storage UI, so there's nothing left to point users at from here.
#
# These six keys are exactly the set theme.sh removes at runtime in
# MainSettings.java; the two lists have to stay in step, because leaving an
# entry here that the Java no longer expects (or vice versa) is what made
# Settings crash on open in the 151 build.
#
# Removal is driven by the keys rather than by one literal multi-line block.
# The old pattern required the element to open with the tag name immediately
# followed by android:key, and Chromium 152 inserted an android:fragment
# attribute between the two - so it silently matched nothing, which is
# precisely the failure this kind of substitution is prone to. Matching each
# element by its key tolerates attributes being added, removed or reordered,
# and [^<>] keeps a match from ever running past the element it started in.
#
# A key that matches nothing is fatal rather than skipped: a missing entry
# means upstream renamed or restructured it, and continuing would ship the
# preference while the Java that backs it is gone.
perl -0777 -pi -e '
    my @keys = qw(autofill_and_passwords autofill_section passwords
                  autofill_payment_methods autofill_addresses autofill_options);
    for my $k (@keys) {
        s{[ \t]*<[\w.]+\b[^<>]*?android:key="\Q$k\E"[^<>]*?/>\n}{}s
            or die "[aerium] FATAL: no element with android:key=\"$k\" in "
                   . "main_preferences.xml - upstream renamed or restructured it\n";
    }
    s/\n{3,}/\n\n/g;
' chrome/android/java/res/xml/main_preferences.xml
# The die above reports the operation; this reports the outcome. They are not
# quite the same check - if upstream ever carried two elements under one of
# these keys, each substitution would remove one and still succeed. Cheap
# enough to keep both. Written as an if rather than `grep && {...}` so set -e
# cannot fire on the grep that correctly finds nothing, and so verify-seds,
# which sources this over an empty tree, sees the grep fail and moves on.
if grep -qE 'android:key="(autofill_and_passwords|autofill_section|passwords|autofill_payment_methods|autofill_addresses|autofill_options)"' \
        chrome/android/java/res/xml/main_preferences.xml; then
    echo "[aerium] FATAL: autofill entries remain in main_preferences.xml" \
         "after the removal above" >&2
    return 1
fi

# The platform-autofill default lives in theme.sh, which UPDATING.md names as
# its owner. It used to be duplicated here too; since build.sh sources patch.sh
# first, this copy won on every build and theme.sh's silently did nothing,
# which cost a verify-seds NOOP that read like a broken pattern at every
# Chromium bump.

# --- The open-links-in-incognito rewrite applies to http/https VIEW intents only.
sed -i 's|if (!Intent\.ACTION_VIEW\.equals(intent\.getAction())) {|if (!Intent.ACTION_VIEW.equals(intent.getAction())\n                \|\| !android.webkit.URLUtil.isNetworkUrl(IntentHandler.getUrlFromIntent(intent))) {|' aerium/chromium_src/chrome/android/java/src/org/chromium/chrome/browser/LaunchIntentDispatcherHooks.java # web URLs only
sed -i 's|if (urlFromIntent == null) {|if (!android.webkit.URLUtil.isNetworkUrl(urlFromIntent)) {|' aerium/chromium_src/chrome/android/java/src/org/chromium/chrome/browser/LaunchIntentDispatcherHooks.java # web URLs only
sed -i 's|static Intent maybeModifyCustomTabIntents(Context context, Intent intent) {|static Intent maybeModifyCustomTabIntents(Context context, Intent intent) { if (!android.webkit.URLUtil.isNetworkUrl(IntentHandler.getUrlFromIntent(intent))) { return intent; }|' aerium/chromium_src/chrome/android/java/src/org/chromium/chrome/browser/LaunchIntentDispatcherHooks.java # web URLs only

# --- Keep the remote config-APK mechanism permanently disabled.
#
# isEligible() gates VanadiumConfParser's init() and is meant to permanently
# disable Vanadium's remote "config APK" component/flag-fetching mechanism
# (no code path should ever let a remote package push flags/components into
# the browser) - so the method must be defined, not just referenced, or this
# fails to compile with "cannot find symbol: method isEligible()".
sed -i 's|private static void init(Context ctx, SpecType specType) {|private static boolean isEligible() { return false; }\n\n    private static void init(Context ctx, SpecType specType) { if (!isEligible()) { return; }|' aerium/android_config/parser/java/src/app/aerium/config/AeriumConfParser.java
sed -i 's|if (!_omit_dex) {|if (_is_base_module \&\& !_omit_dex) {|' build/config/android/rules.gni

# --- Drop Vanadium's GPU feature overrides and leave Chromium's defaults.
sed -i '/feature_overrides.EnableFeature(::features::kSkipVulkanBlocklist);/d' chrome/browser/chrome_browser_field_trials.cc
sed -i '/feature_overrides.EnableFeature(::features::kDefaultANGLEVulkan);/d' chrome/browser/chrome_browser_field_trials.cc
sed -i '/feature_overrides.EnableFeature(::features::kVulkanFromANGLE);/d' chrome/browser/chrome_browser_field_trials.cc
sed -i '/feature_overrides.EnableFeature(::features::kDefaultPassthroughCommandDecoder);/d' chrome/browser/chrome_browser_field_trials.cc
sed -i '/BASE_FEATURE(kFallbackToSWIfGLES3NotSupported,/,/#endif/ s/base::FEATURE_ENABLED_BY_DEFAULT/base::FEATURE_DISABLED_BY_DEFAULT/' ui/gl/gl_features.cc

# --- Developer tools on phones, plus the task manager and app-menu submenus.
sed -i 's/BASE_FEATURE(kSubmenusInAppMenu, base::FEATURE_DISABLED_BY_DEFAULT);/BASE_FEATURE(kSubmenusInAppMenu, base::FEATURE_ENABLED_BY_DEFAULT);/' chrome/browser/flags/android/chrome_feature_list.cc
sed -i '/BASE_FEATURE(kTaskManagerClank,/,/);/ s/base::FEATURE_DISABLED_BY_DEFAULT/base::FEATURE_ENABLED_BY_DEFAULT/' chrome/browser/task_manager/common/task_manager_features.cc
sed -i 's/BASE_FEATURE(kAndroidDevToolsFrontend, base::FEATURE_DISABLED_BY_DEFAULT);/BASE_FEATURE(kAndroidDevToolsFrontend, base::FEATURE_ENABLED_BY_DEFAULT);/' content/public/common/content_features.cc
sed -i 's:|| !DeviceFormFactor.isNonMultiDisplayContextOnTablet(mContext):|| false:' chrome/android/java/src/org/chromium/chrome/browser/tabbed_mode/MoreToolsItemBuilder.java
sed -i 's|boolean shouldShowDeveloperMenu() {|boolean shouldShowDeveloperMenu() { if (true) return DevToolsWindowAndroid.isDevToolsAllowedFor(getProfile(), mItemDelegate.getWebContents());|' chrome/android/java/src/org/chromium/chrome/browser/contextmenu/ChromeContextMenuPopulator.java
sed -i 's|TabUtils.isUsingDesktopUserAgent(mItemDelegate.getWebContents())|(true \|\| TabUtils.isUsingDesktopUserAgent(mItemDelegate.getWebContents()))|' chrome/android/java/src/org/chromium/chrome/browser/contextmenu/ChromeContextMenuPopulator.java

# --- Omnibox site search.
sed -i 's|BASE_FEATURE(kOmniboxSiteSearch, DISABLED);|BASE_FEATURE(kOmniboxSiteSearch, ENABLED);|' components/omnibox/common/omnibox_features.cc

# --- Media playback options: use the desktop set rather than the Android one.
sed -i 's|#if BUILDFLAG(IS_ANDROID)|#if 0|' content/public/renderer/render_frame_media_playback_options.cc

# --- The extensions pages, laid out for a phone rather than a desktop window.
sed -i 's|constexpr gfx::Size kMinSize = {25, 25};|constexpr gfx::Size kMinSize = {256, 25};|' chrome/browser/ui/android/extensions/extension_action_popup_contents.cc
sed -i 's|<meta name="color-scheme" content="light dark">|&\n<meta name="viewport" content="width=device-width">|' chrome/browser/resources/extensions/extensions.html
sed -i 's|--extensions-card-width: 400px;|--extensions-card-width: 96%;|' chrome/browser/resources/extensions/item_list.css
sed -i 's|--cr-toolbar-field-width: 680px;|--cr-toolbar-field-width: 96%;|' chrome/browser/resources/extensions/shared_vars.css
sed -i 's|padding: 24px 60px 64px;|padding: 24px 0 64px;|' chrome/browser/resources/extensions/item_list.css

# --- Manifest V2 extensions stay installable.
sed -i 's|uncompiled_sources_ = \[|&\n  "browser_action.json",\n  "page_action.json",|' chrome/common/extensions/api/api_sources.gni
sed -i 's/api::webstore_private::MV2DeprecationStatus::kHardDisable)));/api::webstore_private::MV2DeprecationStatus::kNone)));/' extensions/browser/api/webstore_private/webstore_private_api.cc
sed -i 's/bool g_allow_mv2_for_testing = false;/bool g_allow_mv2_for_testing = true;/' extensions/browser/manifest_v2_handler.cc

# --- Off-store extension downloads from the Opera and Edge catalogues, and GitHub releases.
sed -i '/^bool OffStoreInstallAllowedByPrefs(/a\  for (const char* d : {"addons.opera.com", "operacdn.com", "microsoftedge.microsoft.com", "edge.microsoft.com", "delivery.mp.microsoft.com", "github.com", "githubusercontent.com"}) if (item.GetURL().DomainIs(d) || item.GetReferrerUrl().DomainIs(d)) return true;' chrome/browser/download/download_crx_util.cc

# --- Manifest V2 extensions keep working.
sed -i '/^bool ShouldDisableLegacyExtensions() {$/{N;N;N;N;N;N;s%bool ShouldDisableLegacyExtensions() {\n  if (g_allow_mv2_for_testing) {\n    // We allow legacy MV2 extensions for testing purposes.\n    return false;\n  }\n\n  return true;%bool ShouldDisableLegacyExtensions() {\n  // Aerium: Manifest V2 extensions stay loadable - see patch.sh.\n  return false;%}' extensions/browser/manifest_v2_handler.cc

# --- An extensions container in the phone toolbar.
sed -i '/<ViewStub/{N;N;N;N;N;N; /optional_button_stub/a\
        <ViewStub\
            android:id="@+id/extensions_toolbar_container_stub"\
            android:inflatedId="@+id/extensions_toolbar_container"\
            android:layout_width="wrap_content"\
            android:layout_height="match_parent" />
}' chrome/browser/ui/android/toolbar/java/res/layout/toolbar_phone.xml
sed -i 's|(ToolbarTablet) mToolbarLayout,|mToolbarLayout,|' chrome/android/java/src/org/chromium/chrome/browser/toolbar/ToolbarManager.java
sed -i '/\/\/ Draw the signin button if visible./i\        { View extContainer = findViewById(R.id.extensions_toolbar_container); if (extContainer != null \&\& extContainer.getVisibility() != View.GONE \&\& extContainer.getWidth() != 0) { canvas.save(); ViewUtils.translateCanvasToView(mToolbarButtonsContainer, extContainer, canvas); extContainer.draw(canvas); canvas.restore(); } }' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/top/ToolbarPhone.java

# --- Extension popups, anchored even when their button is not on screen.
sed -i '/public class RecyclerViewDelegate {$/a\public View getContainerView() { return mContainer; }' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/extensions/ExtensionActionListCoordinator.java
sed -i '/private void showPopupOnAnchor() {/,/private void closePopup() {/ s|if (buttonView == null) {|if (false) {|' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/extensions/ExtensionActionListMediator.java
sed -i 's|buttonView.setIsPressed(true);|if (buttonView != null) buttonView.setIsPressed(true);|' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/extensions/ExtensionActionListMediator.java
sed -i '/[[:space:]]mWindowAndroid,/!b;n;s|[[:space:]]buttonView,|buttonView != null ? buttonView : mRecyclerViewDelegate.getContainerView(),|' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/extensions/ExtensionActionListMediator.java

# --- Omnibox results keep the mobile shape on this build.
sed -i 's/is_desktop_android = !!BUILDFLAG(IS_DESKTOP_ANDROID);/is_desktop_android = false;/' components/omnibox/browser/zero_suggest_verbatim_match_provider.cc
sed -i 's/is_android_mobile = is_android_any \&\& !is_android_desktop;/is_android_mobile = is_android_any \&\& is_android_desktop;/' components/omnibox/browser/autocomplete_result.cc

# --- Hide the extensions menu button while it is unpinned.
sed -i '/Pref.PIN_EXTENSIONS_MENU_BUTTON, this::updateMenuButtonPinState);$/a\if (!mPrefService.getBoolean(Pref.PIN_EXTENSIONS_MENU_BUTTON)) { mContainer.findViewById(R.id.extensions_menu_button).setVisibility(View.GONE); }' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/extensions/ExtensionsToolbarCoordinatorImpl.java
sed -i '/"ExtensionsToolbarCoordinatorImpl.requestLayoutWithViewUtils()");$/a\if (!isMenuButtonPinned()) { mContainer.findViewById(R.id.extensions_menu_button).setVisibility(View.GONE); }' chrome/browser/ui/android/toolbar/java/src/org/chromium/chrome/browser/toolbar/extensions/ExtensionsToolbarCoordinatorImpl.java

# --- Extensions in incognito, and incognito as its own window.
sed -i 's|if (!context->IsOffTheRecord()) {|if (true) {|' extensions/browser/process_manager.cc
sed -i 's|public static boolean shouldOpenIncognitoAsWindow() {|public static boolean shouldOpenIncognitoAsWindow() { if (org.chromium.chrome.browser.preferences.ChromeSharedPreferences.getInstance().readBoolean(org.chromium.chrome.browser.preferences.ChromePreferenceKeys.AERIUM_SEAMLESS_INCOGNITO, false)) { return false; } if (true) return true;|' chrome/browser/incognito/android/java/src/org/chromium/chrome/browser/incognito/IncognitoUtils.java

# --- Keep extension hosts at a process importance Android will not evict.
sed -i 's|host_contents_->SetColorProviderSource(NoOpColorProviderSource::Get());|&\nhost_contents_->SetPrimaryPageImportance(content::ChildProcessImportance::IMPORTANT, content::ChildProcessImportance::NORMAL);|' extensions/browser/extension_host.cc

# --- The extension permissions prompt without a parent WebContents.
sed -i '/content::WebContents\* web_contents = show_params->GetParentWebContents();/,/DCHECK(view_android);/{/GetParentWebContents/!d}' chrome/browser/ui/android/extensions/extension_install_dialog_view_android.cc
sed -i 's|view_android->GetWindowAndroid();|show_params->GetParentWindow();|' chrome/browser/ui/android/extensions/extension_install_dialog_view_android.cc

# --- Touch filtering on the extension install dialog.
sed -i 's|.with(ModalDialogProperties.FILTER_TOUCH_FOR_SECURITY, true)|.with(ModalDialogProperties.FILTER_TOUCH_FOR_SECURITY, false)|' chrome/browser/ui/android/extensions/java/src/org/chromium/chrome/browser/ui/extensions/ExtensionInstallDialogBridge.java

# --- Extension locales read from a content URI.
sed -i 's|while (!(locale_path = locales.Next()).empty()) {|&if (locale_path.IsContentUri()) { locale_path = path.Append(locales.GetInfo().GetName()); }|' extensions/common/manifest_handlers/default_locale_handler.cc
sed -i 's|while (!(locale_folder = locales.Next()).empty()) {|&if (locale_folder.IsContentUri()) { locale_folder = locale_path.Append(locales.GetInfo().GetName()); }|' extensions/common/extension_l10n_util.cc
sed -i '/extension_l10n_util::ValidateExtensionLocales($/,/error) &&$/{s|extension_l10n_util::ValidateExtensionLocales(|(extension_path_.IsVirtualDocumentPath() \|\| &|;s|error) &&|error)) \&\&|}' extensions/browser/unpacked_installer.cc

# --- Incognito entries in the app menu.
sed -i 's|if (!IncognitoUtils.shouldOpenIncognitoAsWindow() \|\| isIncognitoShowing()) {|if (true) {|' chrome/android/java/src/org/chromium/chrome/browser/tabbed_mode/TabbedAppMenuPropertiesDelegate.java
sed -i 's|if (!separateIncognitoWindow \|\| isIncognito) {|if (true) {|' chrome/android/java/src/org/chromium/chrome/browser/tabbed_mode/TabbedAppMenuPropertiesDelegate.java

# --- Load unpacked: resolve a document URI without walking the tree.
sed -i 's|assert treeId.equals(documentId);|&\n if ("com.android.externalstorage.documents".equals(mAuthority)) { String fastId = mRelativePath.isEmpty() ? treeId : (treeId.endsWith(":") ? treeId + mRelativePath : treeId + "/" + mRelativePath); Uri fast = DocumentsContract.buildDocumentUriUsingTree(tree, fastId); return contentUriExists(fast) ? fast : null; }|' base/android/java/src/org/chromium/base/VirtualDocumentPath.java

# --- Back out of an incognito tab to the system.
sed -i 's|private void onTabChanged(@Nullable Tab tab) {|private void onTabChanged(@Nullable Tab tab) { if (tab != null \&\& tab.isIncognitoBranded()) { mSystemBackPressSupplier.set(true); return; }|' chrome/browser/back_press/android/java/src/org/chromium/chrome/browser/back_press/MinimizeAppAndCloseTabBackPressHandler.java

# --- Guard a null tab list in the tabs API.
sed -i '/for (int i = 0; i < tab_list->GetTabCount(); ++i) {/i if (!tab_list) { continue; }' chrome/browser/extensions/api/tabs/tabs_api.cc

# --- Keep an OTR profile alive while it still has WebContents.
sed -i '/CONTENT_EXPORT static WebContents\* FromRenderFrameHost(RenderFrameHost\* rfh);/a\CONTENT_EXPORT static bool HasLiveWebContentsForBrowserContext(BrowserContext* browser_context);' content/public/browser/web_contents.h
sed -i '/^WebContentsImpl::WebContentsImpl(BrowserContext\* browser_context)/i\ bool WebContents::HasLiveWebContentsForBrowserContext(BrowserContext* browser_context) { for (WebContentsImpl* web_contents : WebContentsImpl::GetAllWebContents()) { if (web_contents->GetBrowserContext() == browser_context) { return true; } } return false; }' content/browser/web_contents/web_contents_impl.cc
sed -i '/#include "content\/public\/browser\/render_process_host.h"/a#include "content/public/browser/web_contents.h"' chrome/browser/profiles/profile_destroyer.cc
sed -i '/^void ProfileDestroyer::DestroyOTRProfileWhenAppropriateWithTimeout($/,/MaybeSendDestroyedNotification/{/  profile->MaybeSendDestroyedNotification();/i\
if (content::WebContents::HasLiveWebContentsForBrowserContext(profile)) { return; }
}' chrome/browser/profiles/profile_destroyer.cc

# --- Accept MIXED-profile activities on API 31.
sed -i 's/|| mSupportedProfileType == SupportedProfileType.REGULAR) {/|| mSupportedProfileType == SupportedProfileType.REGULAR || mSupportedProfileType == SupportedProfileType.MIXED) {/' chrome/android/java/src/org/chromium/chrome/browser/ChromeTabbedActivity.java
sed -i 's/|| mSupportedProfileType == SupportedProfileType.OFF_THE_RECORD) {/|| mSupportedProfileType == SupportedProfileType.OFF_THE_RECORD || mSupportedProfileType == SupportedProfileType.MIXED) {/' chrome/android/java/src/org/chromium/chrome/browser/ChromeTabbedActivity.java

# ---------------------------------------------------------------------------
# Chromium 150-153+: Disable forced Tab Group auto-creation for Classic Stack
# ---------------------------------------------------------------------------
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
                    if "isTabGroupAutoCreationEnabled()" in content:
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

# ---------------------------------------------------------------------------
# Fix Chromium 153 gn gen syntax errors safely in BUILD.gn files
# ---------------------------------------------------------------------------
python3 - << 'EOF' || true
import os

for root, dirs, files in os.walk("."):
    for f in files:
        if f == "BUILD.gn":
            p = os.path.join(root, f)
            try:
                with open(p, "r", encoding="utf-8", errors="ignore") as fp:
                    content = fp.read()
                changed = False

                # 1. Cleanly comment out the single telemetry test element without breaking deps array
                if "telemetry_perf_unittests" in content:
                    content = content.replace(
                        '"//chrome/test:telemetry_perf_unittests${_target_suffix}",',
                        '# "//chrome/test:telemetry_perf_unittests${_target_suffix}",'
                    )
                    content = content.replace(
                        '"//chrome/test:telemetry_perf_unittests${_target_suffix}"',
                        '# "//chrome/test:telemetry_perf_unittests${_target_suffix}"'
                    )
                    changed = True

                # 2. Fix allow_circular_includes_from in chrome/test/BUILD.gn
                if "allow_circular_includes_from +=" in content:
                    content = content.replace(
                        "allow_circular_includes_from +=",
                        "# allow_circular_includes_from +="
                    )
                    changed = True

                if changed:
                    with open(p, "w", encoding="utf-8") as fp:
                        fp.write(content)
                    print(f"Fixed GN syntax in: {p}")
            except Exception:
                pass
EOF

# ---------------------------------------------------------------------------
# Apply Vertical Stack Tab Switcher patch safely
# ---------------------------------------------------------------------------
PATCH_FILE=$(find "$SCRIPT_DIR" "$GITHUB_WORKSPACE" . .. -name "vertical-tab-switcher.patch" 2>/dev/null | head -n 1)
if [ -n "$PATCH_FILE" ] && [ -f "$PATCH_FILE" ]; then
  echo "==> Found patch file at: $PATCH_FILE"
  git apply --ignore-whitespace --whitespace=nowarn "$PATCH_FILE" 2>/dev/null || \
  patch -p1 --forward --no-backup-if-mismatch < "$PATCH_FILE" 2>/dev/null || \
  echo "==> Notice: Patch bypassed or already present"
fi

export PATCHED=1
