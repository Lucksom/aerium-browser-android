#!/usr/bin/env python3
# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

import glob
import os
import re
import shutil
import sys

def find_file(filename, path_hint=""):
    out_sub = f"{os.sep}out{os.sep}"
    tp_sub = f"{os.sep}third_party{os.sep}"
    candidates = glob.glob(f"**/{filename}", recursive=True)
    matches = [
        p
        for p in candidates
        if out_sub not in p
        and not p.startswith(f"out{os.sep}")
        and tp_sub not in p
        and not p.startswith(f"third_party{os.sep}")
    ]
    if path_hint:
        matches = [p for p in matches if path_hint in p]

    if not matches:
        print(f"[FATAL] Target file not found: {filename} (hint: '{path_hint}')")
        sys.exit(1)
    if len(matches) > 1:
        print(f"[FATAL] Ambiguous file resolution for '{filename}'. Multiple candidates found:\n" + "\n".join(matches))
        sys.exit(1)

    return matches[0]

def patch_file(filepath, anchor, replacement, description):
    """Replaces text in a file with strict existence verification (no silent failures)."""
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()

    if replacement in content:
        print(f"[aerium] Already patched: {description}")
        return

    if anchor not in content:
        print(f"\n[FATAL] Anchor text not found in {filepath} for: {description}")
        print("Expected anchor preview:")
        print("--------------------------------------------------")
        print(anchor[:200])
        print("--------------------------------------------------")
        sys.exit(1)

    new_content = content.replace(anchor, replacement, 1)
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(new_content)
    print(f"[aerium] Successfully applied: {description}")

src_root = os.getcwd()
script_dir = os.path.dirname(os.path.abspath(__file__))

possible_dirs = [
    os.path.join(script_dir, "classic_stack"),
    os.path.join(src_root, "patches", "classic_stack"),
    os.path.join(src_root, "..", "patches", "classic_stack"),
]
if "GITHUB_WORKSPACE" in os.environ:
    possible_dirs.insert(0, os.path.join(os.environ["GITHUB_WORKSPACE"], "patches", "classic_stack"))

patch_dir = None
for candidate in possible_dirs:
    if os.path.isdir(candidate):
        patch_dir = os.path.abspath(candidate)
        break

if not patch_dir:
    print(f"[FATAL] Could not locate patches/classic_stack directory. Checked: {possible_dirs}")
    sys.exit(1)

print(f"[aerium] Resolved patch_dir: {patch_dir}")

# ==============================================================================
# STEP 1: RESTORE MISSING STACK PROPERTIES IN LayoutTab.java
# ==============================================================================
lt_path = find_file("LayoutTab.java", path_hint=os.path.join("compositor", "layouts", "components"))
with open(lt_path, "r", encoding="utf-8") as f:
    lt_c = f.read()

keys_definitions = [
    ("TILT_X_IN_DEGREES", "public static final WritableFloatPropertyKey TILT_X_IN_DEGREES = new WritableFloatPropertyKey();"),
    ("TILT_Y_IN_DEGREES", "public static final WritableFloatPropertyKey TILT_Y_IN_DEGREES = new WritableFloatPropertyKey();"),
    ("SIDE_BORDER_SCALE", "public static final WritableFloatPropertyKey SIDE_BORDER_SCALE = new WritableFloatPropertyKey();"),
    ("BORDER_CLOSE_BUTTON_ALPHA", "public static final WritableFloatPropertyKey BORDER_CLOSE_BUTTON_ALPHA = new WritableFloatPropertyKey();"),
    ("TOOLBAR_Y_OFFSET", "public static final WritableFloatPropertyKey TOOLBAR_Y_OFFSET = new WritableFloatPropertyKey();"),
    ("TOOLBAR_ALPHA", "public static final WritableFloatPropertyKey TOOLBAR_ALPHA = new WritableFloatPropertyKey();"),
    ("SATURATION", "public static final WritableFloatPropertyKey SATURATION = new WritableFloatPropertyKey();"),
    ("CLOSE_BUTTON_IS_ON_RIGHT", "public static final org.chromium.ui.modelutil.PropertyModel.WritableBooleanPropertyKey CLOSE_BUTTON_IS_ON_RIGHT = new org.chromium.ui.modelutil.PropertyModel.WritableBooleanPropertyKey();"),
    ("CLOSE_PLACEMENT", "public static final org.chromium.ui.modelutil.PropertyModel.WritableObjectPropertyKey<android.graphics.RectF> CLOSE_PLACEMENT = new org.chromium.ui.modelutil.PropertyModel.WritableObjectPropertyKey<>();"),
    ("CLOSE_BUTTON_WIDTH_DP", "public static final float CLOSE_BUTTON_WIDTH_DP = 36.0f;"),
    ("IS_TITLE_NEEDED", "public static final org.chromium.ui.modelutil.PropertyModel.WritableBooleanPropertyKey IS_TITLE_NEEDED = new org.chromium.ui.modelutil.PropertyModel.WritableBooleanPropertyKey();"),
    ("IS_VISIBLE", "public static final org.chromium.ui.modelutil.PropertyModel.WritableBooleanPropertyKey IS_VISIBLE = new org.chromium.ui.modelutil.PropertyModel.WritableBooleanPropertyKey();"),
    ("CLIPPED_X", "public static final WritableFloatPropertyKey CLIPPED_X = new WritableFloatPropertyKey();"),
    ("CLIPPED_Y", "public static final WritableFloatPropertyKey CLIPPED_Y = new WritableFloatPropertyKey();"),
    ("BOUNDS", "public static final org.chromium.ui.modelutil.PropertyModel.WritableObjectPropertyKey<android.graphics.RectF> BOUNDS = new org.chromium.ui.modelutil.PropertyModel.WritableObjectPropertyKey<>();"),
]

keys_to_inject = []
for key_name, defn in keys_definitions:
    if not re.search(r'\b' + key_name + r'\b', lt_c):
        keys_to_inject.append("    " + defn)

if keys_to_inject:
    keys_anchor = "public static final WritableFloatPropertyKey BORDER_ALPHA = new WritableFloatPropertyKey();"
    if keys_anchor not in lt_c:
        print(f"[FATAL] Keys anchor '{keys_anchor}' not found in {lt_path}")
        sys.exit(1)
    replacement = keys_anchor + "\n" + "\n".join(keys_to_inject)
    lt_c = lt_c.replace(keys_anchor, replacement, 1)
    print(f"[aerium] Injected {len(keys_to_inject)} missing PropertyKey definitions into LayoutTab.java")

all_keys_candidates = [
    "TILT_X_IN_DEGREES", "TILT_Y_IN_DEGREES", "SIDE_BORDER_SCALE",
    "BORDER_CLOSE_BUTTON_ALPHA", "TOOLBAR_Y_OFFSET", "TOOLBAR_ALPHA",
    "SATURATION", "CLOSE_BUTTON_IS_ON_RIGHT", "CLOSE_PLACEMENT",
    "IS_TITLE_NEEDED", "IS_VISIBLE", "CLIPPED_X", "CLIPPED_Y", "BOUNDS",
]

all_keys_match = re.search(r"(ALL_KEYS\s*=\s*(?:new\s+PropertyKey\[\]\s*)?\{)([\s\S]*?)(?=\})", lt_c)
if all_keys_match:
    existing_all_keys = all_keys_match.group(2)
    keys_to_add_to_array = []
    for k in all_keys_candidates:
        if not re.search(r'\b' + k + r'\b', existing_all_keys):
            keys_to_add_to_array.append(f"            {k},")
    if keys_to_add_to_array:
        insert_idx = all_keys_match.start(2)
        addition = "\n" + "\n".join(keys_to_add_to_array)
        lt_c = lt_c[:insert_idx] + addition + lt_c[insert_idx:]
        print(f"[aerium] Injected {len(keys_to_add_to_array)} keys into ALL_KEYS array")

methods_candidates = [
    ("setTiltX", "    public void setTiltX(float angle, float pivot) { mTiltX = angle; }"),
    ("setTiltY", "    public void setTiltY(float angle, float pivot) { mTiltY = angle; }"),
    ("getTiltX", "    public float getTiltX() { return mTiltX; }"),
    ("getTiltY", "    public float getTiltY() { return mTiltY; }"),
    ("setBorderCloseButtonAlpha", "    public void setBorderCloseButtonAlpha(float alpha) { mBorderCloseButtonAlpha = alpha; }"),
    ("getBorderCloseButtonAlpha", "    public float getBorderCloseButtonAlpha() { return mBorderCloseButtonAlpha; }"),
    ("setCloseButtonIsOnRight", "    public void setCloseButtonIsOnRight(boolean onRight) { mCloseButtonOnRight = onRight; }"),
    ("isCloseButtonOnRight", "    public boolean isCloseButtonOnRight() { return mCloseButtonOnRight; }"),
    ("getUnclampedOriginalContentHeight", "    public float getUnclampedOriginalContentHeight() { return getOriginalContentHeight(); }"),
    ("getMaxContentWidth", "    public float getMaxContentWidth() { return mMaxContentWidth > 0 ? mMaxContentWidth : getOriginalContentWidth(); }"),
    ("getMaxContentHeight", "    public float getMaxContentHeight() { return mMaxContentHeight > 0 ? mMaxContentHeight : getOriginalContentHeight(); }"),
    ("setMaxContentWidth", "    public void setMaxContentWidth(float w) { mMaxContentWidth = w; }"),
    ("setMaxContentHeight", "    public void setMaxContentHeight(float h) { mMaxContentHeight = h; }"),
    ("shouldStall", "    public boolean shouldStall() { return false; }"),
    ("setInsetBorderVertical", "    public void setInsetBorderVertical(boolean inset) {}"),
    ("setShowToolbar", "    public void setShowToolbar(boolean show) {}"),
    ("setToolbarAlpha", "    public void setToolbarAlpha(float alpha) { set(TOOLBAR_ALPHA, alpha); }"),
    ("getToolbarAlpha", "    public float getToolbarAlpha() { return has(TOOLBAR_ALPHA) ? get(TOOLBAR_ALPHA) : 0f; }"),
    ("setAnonymizeToolbar", "    public void setAnonymizeToolbar(boolean anonymize) {}"),
    ("setDrawDecoration", "    public void setDrawDecoration(boolean draw) {}"),
    ("setDecorationAlpha", "    public void setDecorationAlpha(float alpha) {}"),
    ("setBorderScale", "    public void setBorderScale(float scale) {}"),
    ("getFinalContentWidth", "    public float getFinalContentWidth() { return getScaledContentWidth(); }"),
    ("getFinalContentHeight", "    public float getFinalContentHeight() { return getScaledContentHeight(); }"),
    ("isVisible", "    public boolean isVisible() { return has(IS_VISIBLE) ? get(IS_VISIBLE) : true; }"),
    ("setVisible", "    public void setVisible(boolean visible) { set(IS_VISIBLE, visible); }"),
    ("setClipOffset", "    public void setClipOffset(float x, float y) { set(CLIPPED_X, x); set(CLIPPED_Y, y); }"),
    ("getClippedX", "    public float getClippedX() { return has(CLIPPED_X) ? get(CLIPPED_X) : 0f; }"),
    ("getClippedY", "    public float getClippedY() { return has(CLIPPED_Y) ? get(CLIPPED_Y) : 0f; }"),
]

methods_to_inject = []
for method_name, method_code in methods_candidates:
    if not re.search(r'\b' + method_name + r'\s*\(', lt_c):
        methods_to_inject.append(method_code)

fields_code = ""
if "private float mTiltX;" not in lt_c:
    fields_code += """    private float mTiltX;
    private float mTiltY;
    private float mMaxContentWidth;
    private float mMaxContentHeight;
    private boolean mCloseButtonOnRight;
    private float mBorderCloseButtonAlpha;
"""
if "private boolean has(" not in lt_c:
    fields_code += """    private boolean has(org.chromium.ui.modelutil.PropertyModel.WritableFloatPropertyKey key) {
        try { return get(key) != 0.0f; } catch (Exception e) { return false; }
    }
    private boolean has(org.chromium.ui.modelutil.PropertyModel.WritableBooleanPropertyKey key) {
        try { return get(key); } catch (Exception e) { return false; }
    }
"""

if methods_to_inject or fields_code:
    ctor_match = re.search(r"public\s+LayoutTab\s*\(", lt_c)
    if not ctor_match:
        print(f"[FATAL] Could not find 'public LayoutTab(' constructor in {lt_path}")
        sys.exit(1)
    idx = ctor_match.start()
    addition = fields_code + "\n".join(methods_to_inject) + "\n\n    "
    lt_c = lt_c[:idx] + addition + lt_c[idx:]
    print(f"[aerium] Injected {len(methods_to_inject)} methods into LayoutTab.java")

with open(lt_path, "w", encoding="utf-8") as f:
    f.write(lt_c)
print("[aerium] Step 1: LayoutTab.java successfully updated")

# ==============================================================================
# STEP 2: INJECT SHOW_CLOSE_BUTTON IN Layout.java
# ==============================================================================
l_path = find_file("Layout.java", path_hint=os.path.join("compositor", "layouts"))
layout_anchor = "public LayoutTab createLayoutTab(int id, boolean isIncognito) {"
layout_replacement = """public static final boolean SHOW_CLOSE_BUTTON = true;

    public LayoutTab createLayoutTab(int id, boolean isIncognito) {"""
patch_file(l_path, layout_anchor, layout_replacement, "Layout.java SHOW_CLOSE_BUTTON")

# ==============================================================================
# STEP 3: DEPLOY & PRECISELY SANITIZE M88 JAVA SOURCES
# ==============================================================================
dest_scene_layer = os.path.join(src_root, "chrome", "android", "java", "src", "org", "chromium", "chrome", "browser", "compositor", "scene_layer")
dest_layouts_phone = os.path.join(src_root, "chrome", "android", "java", "src", "org", "chromium", "chrome", "browser", "compositor", "layouts", "phone")
dest_layouts_stack = os.path.join(src_root, "chrome", "android", "java", "src", "org", "chromium", "chrome", "browser", "compositor", "layouts", "phone", "stack")

file_mappings = {
    "ClassicStackSceneLayer.java": dest_scene_layer,
    "StackLayoutBase.java": dest_layouts_phone,
    "StackLayout.java": dest_layouts_phone,
    "Stack.java": dest_layouts_stack,
    "StackTab.java": dest_layouts_stack,
    "StackAnimation.java": dest_layouts_stack,
    "OverlappingStack.java": dest_layouts_stack,
    "StackScroller.java": dest_layouts_stack,
    "StackViewAnimation.java": dest_layouts_stack,
}

KNOWN_DELETED_RESOURCES = [
    "R.dimen.stacked_tab_visible_size", "R.dimen.stack_buffer_width",
    "R.dimen.stack_buffer_height", "R.dimen.over_scroll", "R.integer.over_scroll_angle",
    "R.dimen.over_scroll_slide", "R.dimen.tabswitcher_border_frame_transparent_top",
    "R.dimen.tabswitcher_border_frame_transparent_side", "R.dimen.tabswitcher_border_frame_padding_top",
    "R.dimen.tabswitcher_border_frame_padding_left", "R.dimen.compositor_button_slop",
    "R.dimen.even_out_scrolling", "R.dimen.min_spacing", "R.dimen.open_new_tab_animation_y_translation",
]

for filename, target_dir in file_mappings.items():
    src_file = os.path.join(patch_dir, filename)
    if not os.path.exists(src_file):
        print(f"[FATAL] Source file {filename} does not exist in {patch_dir}!")
        sys.exit(1)

    os.makedirs(target_dir, exist_ok=True)
    with open(src_file, "r", encoding="utf-8") as f:
        content = f.read()

    # Universal import modernizations
    content = content.replace(
        "import org.chromium.chrome.browser.compositor.layouts.eventfilter.ScrollDirection;",
        "import org.chromium.components.browser_ui.widget.gesture.SwipeGestureListener.ScrollDirection;"
    )
    content = content.replace(
        "import org.chromium.components.browser_ui.widget.animation.Interpolators;",
        "import org.chromium.ui.interpolators.Interpolators;"
    )
    content = content.replace(
        "import org.chromium.ui.interpolators.BakedBezierInterpolator;",
        "import org.chromium.ui.interpolators.Interpolators;"
    )
    content = content.replace("BakedBezierInterpolator.FADE_OUT_CURVE", "Interpolators.FAST_OUT_SLOW_IN_INTERPOLATOR")

    # Purge dead feature flags
    content = re.sub(r'import\s+org\.chromium\.chrome\.browser\.flags\.CachedFeatureFlags;[\r\n]+', '', content)
    content = content.replace("CachedFeatureFlags.isEnabled(ChromeFeatureList.HORIZONTAL_TAB_SWITCHER_ANDROID)", "false")
    content = content.replace("ChromeFeatureList.isEnabled(ChromeFeatureList.HORIZONTAL_TAB_SWITCHER_ANDROID)", "false")

    # File specific patches
    if filename == "StackLayoutBase.java":
        if "import android.os.SystemClock;" not in content:
            content = "import android.os.SystemClock;\n" + content
        if "import org.chromium.chrome.browser.tabmodel.TabClosureParams;" not in content:
            content = "import org.chromium.chrome.browser.tabmodel.TabClosureParams;\n" + content

        content = content.replace("LayoutManager.time()", "SystemClock.uptimeMillis()")

        # Direct BrowserControlsStateProvider observer attachment
        content = re.sub(r'import\s+org\.chromium\.base\.supplier\.ObservableSupplier;[\r\n]+', '', content)
        content = re.sub(r'private\s+final\s+ObservableSupplier<BrowserControlsStateProvider>\s+mBrowserControlsSupplier;[\r\n]+', 'private final BrowserControlsStateProvider mBrowserControlsSupplier;\n', content)
        content = re.sub(r'private\s+final\s+Callback<BrowserControlsStateProvider>\s+mBrowserControlsSupplierObserver;[\r\n]+', '', content)
        content = content.replace("ObservableSupplier<BrowserControlsStateProvider>", "BrowserControlsStateProvider")
        content = content.replace("browserControlsStateProviderSupplier.get()", "browserControlsStateProviderSupplier")
        content = content.replace("mBrowserControlsSupplier.get()", "mBrowserControlsSupplier")
        content = content.replace("mBrowserControlsSupplier.hasValue()", "(mBrowserControlsSupplier != null)")

        # Replace supplier callback hook with direct observer attachment
        obs_pattern = r'mBrowserControlsSupplierObserver\s*=\s*\([^)]*\)\s*->[^;]+;[\s\S]*?mBrowserControlsSupplier\.addObserver\(mBrowserControlsSupplierObserver\);'
        content = re.sub(obs_pattern, 'mBrowserControlsSupplier.addObserver(mBrowserControlsObserver);', content)

        # Replace destroy cleanup
        destroy_clean = """if (mBrowserControlsSupplier != null) {
            mBrowserControlsSupplier.removeObserver(mBrowserControlsObserver);
        }"""
        content = re.sub(r'if\s*\(mBrowserControlsSupplier\s*!=\s*null\)\s*\{[\s\S]*?mBrowserControlsSupplier\.removeObserver\(mBrowserControlsSupplierObserver\);[\s\S]*?\}', destroy_clean, content)

        # Fix startHiding and field mNextTabId
        if "protected int mNextTabId" not in content:
            content = re.sub(r'(public\s+abstract\s+class\s+StackLayoutBase[^{]*\{)', r'\1\n    protected int mNextTabId = org.chromium.chrome.browser.tab.Tab.INVALID_TAB_ID;\n', content)

        content = re.sub(r'@Override\s+public\s+void\s+startHiding\(int\s+nextTabId,\s*boolean\s+hintAtTabSelection\)\s*\{[\s\S]*?super\.startHiding\(nextTabId,\s*hintAtTabSelection\);',
                         'public void startHiding(int nextTabId, boolean hintAtTabSelection) {\n        mNextTabId = nextTabId;\n        super.startHiding();', content)

        # Tab closure modernisation
        content = content.replace(
            "TabModelUtils.closeTabById(mTabModelSelector.getModel(incognito), id, canUndo);",
            """{
            org.chromium.chrome.browser.tab.Tab tabToClose = mTabModelSelector.getModel(incognito).getTabById(id);
            if (tabToClose != null) {
                mTabModelSelector.getModel(incognito).getTabRemover().closeTabs(
                        TabClosureParams.closeTab(tabToClose).allowUndo(canUndo).build(), false);
            }
        }"""
        )
        content = content.replace(
            "mTabModelSelector.getModel(incognito).closeAllTabs(false, false);",
            "mTabModelSelector.getModel(incognito).getTabRemover().closeTabs(TabClosureParams.closeAllTabs().allowUndo(false).build(), false);"
        )

        # Replace getCurrentModelIndex
        content = content.replace("mTabModelSelector.getCurrentModelIndex()", "(mTabModelSelector.isIncognitoSelected() ? 1 : 0)")

        # Replace non-static HomepageManager call
        content = content.replace("HomepageManager.shouldCloseAppWithZeroTabs()", "HomepageManager.getInstance().shouldCloseAppWithZeroTabs()")

        # Fix setTabModelSelector super call & remove invalid overrides
        content = re.sub(r'@Override\s+public\s+void\s+setTabModelSelector\(TabModelSelector\s+modelSelector,\s*TabContentManager\s+manager\)\s*\{[\s\S]*?super\.setTabModelSelector\(modelSelector,\s*manager\);',
                         'public void setTabModelSelector(TabModelSelector modelSelector, TabContentManager manager) {\n        super.setTabModelSelector(modelSelector);\n        setTabContentManager(manager);', content)

        content = re.sub(r'@Override\s+public\s+void\s+onTabSelecting\([^\)]*\)\s*\{[\s\S]*?super\.onTabSelecting\([^\)]*\);',
                         'public void onTabSelecting(long time, int tabId) {', content)
        content = re.sub(r'@Override\s+public\s+void\s+onTabRestored\([^\)]*\)\s*\{[\s\S]*?super\.onTabRestored\([^\)]*\);',
                         'public void onTabRestored(long time, int tabId) {', content)

        # Remove dead debug rect
        content = re.sub(r'mRenderHost\.pushDebugRect\([^\)]*\);', '', content)

        # Scene layer push
        push_pattern = r"mSceneLayer\.pushLayers\s*\([^;]+?\);"
        push_replacement = """mSceneLayer.pushLayers(getContext(), viewport, contentViewport, this,
                tabContentManager, resourceManager, browserControls,
                SceneLayer.INVALID_RESOURCE_ID, 0, 0);"""
        content, _ = re.subn(push_pattern, push_replacement, content, count=1)

    elif filename == "StackLayout.java":
        if "import org.chromium.chrome.browser.layouts.LayoutType;" not in content:
            content = "import org.chromium.chrome.browser.layouts.LayoutType;\n" + content
        content = re.sub(r'import\s+org\.chromium\.base\.supplier\.ObservableSupplier;[\r\n]+', '', content)
        content = content.replace("ObservableSupplier<BrowserControlsStateProvider>", "BrowserControlsStateProvider")

        # Implement abstract getLayoutType()
        if "public @LayoutType int getLayoutType()" not in content:
            content = re.sub(r'(public\s+class\s+StackLayout\s+extends\s+StackLayoutBase\s*\{)',
                             r'\1\n    @Override\n    public @LayoutType int getLayoutType() {\n        return LayoutType.HUB;\n    }\n', content)

        # Fix model filter provider removed
        content = content.replace(
            "if (modelSelector.getTabModelFilterProvider().getCurrentTabModelFilter() == null) {",
            "if (modelSelector.getCurrentModel() == null) {"
        )
        content = content.replace(
            "tabLists.add(modelSelector.getTabModelFilterProvider().getTabModelFilter(false));",
            "tabLists.add(modelSelector.getModel(false));"
        )
        content = content.replace(
            "tabLists.add(modelSelector.getTabModelFilterProvider().getTabModelFilter(true));",
            "tabLists.add(modelSelector.getModel(true));"
        )

        content = content.replace(
            "TabModelUtils.getTabById(mTabModelSelector.getModel(true), tabId)",
            "mTabModelSelector.getModel(true).getTabById(tabId)"
        )

        content = re.sub(r'@Override\s+public\s+void\s+onTabsAllClosing\([^\)]*\)\s*\{[\s\S]*?super\.onTabsAllClosing\([^\)]*\);',
                         'public void onTabsAllClosing(long time, boolean incognito) {', content)

    elif filename == "Stack.java":
        content = content.replace("!mLayout.isHiding()", "!mLayout.isStartingToHide()")
        create_pattern = r"mLayout\.createLayoutTab\s*\([^;]+?\);"
        create_replacement = "mLayout.createLayoutTab(tabId, isIncognito);"
        content, _ = re.subn(create_pattern, create_replacement, content, count=1)

        # TabList helpers
        tab_list_helpers = """
    private int getTabIndexInList(TabList list, int id) {
        if (list == null) return TabList.INVALID_TAB_INDEX;
        for (int i = 0; i < list.getCount(); i++) {
            org.chromium.chrome.browser.tab.Tab t = list.getTabAt(i);
            if (t != null && t.getId() == id) return i;
        }
        return TabList.INVALID_TAB_INDEX;
    }

    private org.chromium.chrome.browser.tab.Tab getTabFromList(TabList list, int id) {
        if (list == null) return null;
        for (int i = 0; i < list.getCount(); i++) {
            org.chromium.chrome.browser.tab.Tab t = list.getTabAt(i);
            if (t != null && t.getId() == id) return t;
        }
        return null;
    }
"""
        if "getTabIndexInList" not in content:
            content = re.sub(r'(public\s+class\s+Stack\s*\{)', r'\1' + tab_list_helpers, content)

        content = content.replace("TabModelUtils.getTabIndexById(mTabList, id)", "getTabIndexInList(mTabList, id)")
        content = content.replace("TabModelUtils.getTabById(mTabList, id)", "getTabFromList(mTabList, id)")

    elif filename == "StackViewAnimation.java":
        content = content.replace("TabThemeColorHelper.getBackgroundColor(tab)", "tab.getThemeColor()")

    elif filename == "OverlappingStack.java":
        content = content.replace("TabUiFeatureUtilities.isConditionalTabStripEnabled()", "false")

    # Neutralize deleted resources
    content = content.replace("res.getDimensionPixelOffset(R.dimen.stacked_tab_visible_size) * pxToDp", "28.0f")
    content = content.replace("res.getDimensionPixelOffset(R.dimen.stack_buffer_width) * pxToDp", "0.0f")
    content = content.replace("res.getDimensionPixelOffset(R.dimen.stack_buffer_height) * pxToDp", "0.0f")
    content = content.replace("res.getDimensionPixelOffset(R.dimen.over_scroll)", "Math.round(40.0f * res.getDisplayMetrics().density)")
    content = content.replace("res.getInteger(R.integer.over_scroll_angle)", "15")
    content = content.replace("res.getDimensionPixelOffset(R.dimen.over_scroll_slide) * pxToDp", "20.0f")
    content = content.replace("res.getDimension(R.dimen.tabswitcher_border_frame_transparent_top) * pxToDp", "8.0f")
    content = content.replace("res.getDimension(R.dimen.tabswitcher_border_frame_transparent_side) * pxToDp", "8.0f")
    content = content.replace("res.getDimension(R.dimen.tabswitcher_border_frame_padding_top) * pxToDp", "16.0f")
    content = content.replace("res.getDimension(R.dimen.tabswitcher_border_frame_padding_left) * pxToDp", "8.0f")
    content = content.replace("res.getDimension(R.dimen.compositor_button_slop) * pxToDp", "24.0f")
    content = content.replace("1.0f / (res.getDimension(R.dimen.even_out_scrolling) * pxToDp)", "1.0f / 200.0f")
    content = content.replace("res.getDimensionPixelOffset(R.dimen.min_spacing) * pxToDp", "64.0f")
    content = content.replace("resources.getDimensionPixelSize(R.dimen.open_new_tab_animation_y_translation)", "(int) (50.0f * resources.getDisplayMetrics().density)")

    for deleted_res in KNOWN_DELETED_RESOURCES:
        if deleted_res in content:
            print(f"[FATAL] Unreplaced deleted resource '{deleted_res}' found in {filename}")
            sys.exit(1)

    dest_file = os.path.join(target_dir, filename)
    with open(dest_file, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"[aerium] Deployed: {filename} -> {dest_file}")

# ==============================================================================
# STEP 4: DEPLOY AUTHENTIC NonOverlappingStack.java
# ==============================================================================
non_overlap_file = os.path.join(dest_layouts_stack, "NonOverlappingStack.java")
with open(non_overlap_file, "w", encoding="utf-8") as f:
    f.write("""// Copyright 2018 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package org.chromium.chrome.browser.compositor.layouts.phone.stack;

import android.content.Context;
import androidx.annotation.IntDef;
import org.chromium.chrome.browser.compositor.layouts.components.LayoutTab;
import org.chromium.chrome.browser.compositor.layouts.phone.StackLayoutBase;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;

public class NonOverlappingStack extends Stack {
    @IntDef({SwitchDirection.LEFT, SwitchDirection.RIGHT})
    @Retention(RetentionPolicy.SOURCE)
    public @interface SwitchDirection {
        int LEFT = 0;
        int RIGHT = 1;
    }

    private static final float SCALE_FRACTION_SINGLE_TAB = 0.80f;
    private static final float SCALE_FRACTION_MULTIPLE_TABS = 0.54f;
    private static final float SPACING_SCREEN = 1.0f;
    private static final float EXTRA_SPACE_BETWEEN_TABS_DP = 25.0f;
    private static final float STACK_PORTRAIT_Y_OFFSET_PROPORTION = 0.f;
    private static final float STACK_LANDSCAPE_START_OFFSET_PROPORTION = 0.f;
    private static final float STACK_LANDSCAPE_Y_OFFSET_PROPORTION = 0.f;

    private boolean mSuppressScrollClamping;
    private boolean mSwitchedAway;
    private long mLastTouchDownTime;
    private int mCenteredTabAtTouchDown;

    public NonOverlappingStack(Context context, StackLayoutBase layout) { super(context, layout); }

    private int getNonDyingTabCount() {
        if (mStackTabs == null) return 0;
        int dyingCount = 0;
        for (int i = 0; i < mStackTabs.length; i++) {
            if (mStackTabs[i].isDying()) dyingCount++;
        }
        return mStackTabs.length - dyingCount;
    }

    @Override
    public float getScaleAmount() {
        if (getNonDyingTabCount() > 1) return SCALE_FRACTION_MULTIPLE_TABS;
        return SCALE_FRACTION_SINGLE_TAB;
    }

    @Override
    protected void finishAnimation(long time) {
        super.finishAnimation(time);
        mSuppressScrollClamping = false;
    }

    @Override
    protected boolean evenOutTabs(float amount, boolean allowReverseDirection) { return false; }

    public int getCenteredTabIndex() {
        if (mSpacing == 0) return 0;
        return Math.round(-mScrollOffset / mSpacing);
    }

    @Override
    public void onDown(long time) {
        super.onDown(time);
        mLastTouchDownTime = time;
        mCenteredTabAtTouchDown = getCenteredTabIndex();
        mScroller.setCenteredYSnapIndexAtTouchDown(mCenteredTabAtTouchDown);
    }

    @Override public void onLongPress(long time, float x, float y) {}
    @Override public void onPinch(long time, float x0, float y0, float x1, float y1, boolean firstEvent) {}

    @Override
    protected void springBack(long time) {
        if (!mScroller.isFinished()) return;
        int newTarget = -getCenteredTabIndex() * mSpacing;
        mScroller.flingYTo((int) mScrollTarget, newTarget, time);
        setScrollTarget(newTarget, false);
        mLayout.requestUpdate();
    }

    @Override protected float getSpacingScreen() { return SPACING_SCREEN; }
    @Override protected boolean shouldStackTabsAtTop() { return false; }
    @Override protected boolean shouldStackTabsAtBottom() { return false; }
    @Override protected float getStackPortraitYOffsetProportion() { return STACK_PORTRAIT_Y_OFFSET_PROPORTION; }
    @Override protected float getStackLandscapeStartOffsetProportion() { return STACK_LANDSCAPE_START_OFFSET_PROPORTION; }
    @Override protected float getStackLandscapeYOffsetProportion() { return STACK_LANDSCAPE_Y_OFFSET_PROPORTION; }

    @Override
    protected void computeTabClippingVisibilityHelper() {
        int centeredTab = getCenteredTabIndex();
        if (mStackTabs == null) return;
        for (int i = 0; i < mStackTabs.length; i++) {
            LayoutTab layoutTab = mStackTabs[i].getLayoutTab();
            if (i < centeredTab - 1 || i > centeredTab + 2) {
                layoutTab.setVisible(false);
            } else {
                layoutTab.setVisible(true);
            }
        }
    }

    @Override protected int computeReferenceIndex() { return getCenteredTabIndex(); }
    @Override protected boolean shouldCloseGapsBetweenTabs() { return false; }

    @Override
    protected float getMinScroll(boolean allowUnderScroll) {
        if (mSuppressScrollClamping) return -Float.MAX_VALUE;
        if (mStackTabs == null) return 0;
        for (int i = mStackTabs.length - 1; i >= 0; i--) {
            if (!mStackTabs[i].isDying() && mStackTabs[i].getScrollOffset() != 0) {
                return -mStackTabs[i].getScrollOffset();
            }
        }
        return 0;
    }

    @Override protected boolean allowOverscroll() { return false; }

    @Override
    protected int computeSpacing(int layoutTabCount) {
        return (int) Math.round(getScrollDimensionSize() * getScaleAmount() + EXTRA_SPACE_BETWEEN_TABS_DP);
    }

    @Override
    protected void resetAllScrollOffset() {
        if (mTabList == null) return;
        mScrollOffset = -mTabList.index() * mSpacing;
        setScrollTarget(mScrollOffset, false);
    }

    @Override public float screenToScroll(float screenSpace) { return screenSpace; }
    @Override public float scrollToScreen(float scrollSpace) { return scrollSpace; }

    @Override
    public float getMaxTabHeight() {
        if (getNonDyingTabCount() > 1) return mLayout.getHeight();
        return (SCALE_FRACTION_MULTIPLE_TABS / SCALE_FRACTION_SINGLE_TAB) * mLayout.getHeight();
    }

    public void suppressScrollClampingForAnimation() { mSuppressScrollClamping = true; }

    public void runSwitchAwayAnimation(@SwitchDirection int direction) {
        if (mStackTabs == null || mSwitchedAway) {
            mSwitchedAway = true;
            mLayout.onSwitchAwayFinished();
            return;
        }
        mSwitchedAway = true;
        mSuppressScrollClamping = true;
        for (int i = 0; i < mStackTabs.length; i++) mStackTabs[i].setDiscardAmount(0);
        forceScrollStop();
        mLayout.onSwitchAwayFinished();
    }

    public void runSwitchToAnimation(@SwitchDirection int direction) {
        mSwitchedAway = false;
        mSuppressScrollClamping = false;
        mLayout.onSwitchToFinished();
    }
}
""")
print("[aerium] Step 4: Deployed authentic NonOverlappingStack.java")

# ==============================================================================
# STEP 5: REGISTER SOURCES IN CHROME_JAVA_SOURCES.GNI
# ==============================================================================
gni_path = find_file("chrome_java_sources.gni")
with open(gni_path, "r", encoding="utf-8") as f:
    gni_c = f.read()

m88_entries = [
    '  "java/src/org/chromium/chrome/browser/compositor/layouts/phone/StackLayoutBase.java",\n',
    '  "java/src/org/chromium/chrome/browser/compositor/layouts/phone/StackLayout.java",\n',
    '  "java/src/org/chromium/chrome/browser/compositor/layouts/phone/stack/Stack.java",\n',
    '  "java/src/org/chromium/chrome/browser/compositor/layouts/phone/stack/StackTab.java",\n',
    '  "java/src/org/chromium/chrome/browser/compositor/layouts/phone/stack/StackAnimation.java",\n',
    '  "java/src/org/chromium/chrome/browser/compositor/layouts/phone/stack/StackScroller.java",\n',
    '  "java/src/org/chromium/chrome/browser/compositor/layouts/phone/stack/StackViewAnimation.java",\n',
    '  "java/src/org/chromium/chrome/browser/compositor/layouts/phone/stack/OverlappingStack.java",\n',
    '  "java/src/org/chromium/chrome/browser/compositor/layouts/phone/stack/NonOverlappingStack.java",\n',
    '  "java/src/org/chromium/chrome/browser/compositor/scene_layer/ClassicStackSceneLayer.java",\n',
]

anchor = '"java/src/org/chromium/chrome/browser/compositor/layouts/ToolbarSwipeLayout.java",\n'
new_entries = ""
for entry in m88_entries:
    if entry.strip() not in gni_c:
        new_entries += entry

patch_file(gni_path, anchor, anchor + new_entries, "chrome_java_sources.gni registration")

# ==============================================================================
# STEP 6: HOOK LayoutManagerChromePhone.java
# ==============================================================================
lm_path = find_file("LayoutManagerChromePhone.java")
with open(lm_path, "r", encoding="utf-8") as f:
    lm_c = f.read()

# Add import for StackLayout
if "import org.chromium.chrome.browser.compositor.layouts.phone.StackLayout;" not in lm_c:
    lm_c = re.sub(r'(package\s+[^;]+;[\r\n]+)', r'\1\nimport org.chromium.chrome.browser.compositor.layouts.phone.StackLayout;\n', lm_c)

field_anchor = "private Layout mNewTabAnimationLayout;"
field_repl = """private Layout mNewTabAnimationLayout;
    private @Nullable StackLayout mStackLayout;"""
if "private @Nullable StackLayout mStackLayout;" not in lm_c:
    lm_c = re.sub(r'private\s+@Nullable\s+[^\s]+\s+mStackLayout;', '', lm_c)
    lm_c = lm_c.replace(field_anchor, field_repl, 1)

destroy_anchor = "mNewTabAnimationLayout.destroy();"
destroy_repl = """mNewTabAnimationLayout.destroy();
        if (mStackLayout != null) {
            mStackLayout.destroy();
        }"""
if "mStackLayout.destroy();" not in lm_c:
    lm_c = lm_c.replace(destroy_anchor, destroy_repl, 1)

init_anchor = "mNewTabAnimationLayout.setTabContentManager(tabContentManager);"
init_repl = """mNewTabAnimationLayout.setTabContentManager(tabContentManager);

        mStackLayout =
                new org.chromium.chrome.browser.compositor.layouts.phone.StackLayout(
                        context, this, renderHost, getBrowserControlsManager());
        mStackLayout.setTabModelSelector(selector, tabContentManager);"""

if "new org.chromium.chrome.browser.compositor.layouts.phone.StackLayout(" not in lm_c:
    lm_c = re.sub(
        r'mNewTabAnimationLayout\.setTabContentManager\(tabContentManager\);[\s\S]*?mStackLayout\.setTabModelSelector\(selector,\s*tabContentManager\);',
        'mNewTabAnimationLayout.setTabContentManager(tabContentManager);',
        lm_c
    )
    lm_c = lm_c.replace(init_anchor, init_repl, 1)

if 'aeriumMode' not in lm_c:
    routing_match = re.search(r"@Override\s+protected\s+Layout\s+getLayoutForType\s*\(\s*int\s+layoutType\s*\)\s*\{", lm_c)
    if not routing_match:
        print(f"[FATAL] Could not find getLayoutForType anchor in {lm_path}")
        sys.exit(1)

    idx = routing_match.start()
    routing_hooks = """    @Override
    public void startShowing(Layout layout, boolean animate) {
        String aeriumMode =
                org.chromium.base.ContextUtils.getAppSharedPreferences()
                        .getString("aerium_tab_switcher_mode", "0");
        if (!"0".equals(aeriumMode)) {
            if (layout != null && layout.getLayoutType() == LayoutType.HUB) {
                if (mStackLayout != null) {
                    super.startShowing(mStackLayout, animate);
                    return;
                }
            }
        }
        super.startShowing(layout, animate);
    }

    """
    body_insert = """if (layoutType == LayoutType.SIMPLE_ANIMATION) {
            return mNewTabAnimationLayout;
        }
        String aeriumMode =
                org.chromium.base.ContextUtils.getAppSharedPreferences()
                        .getString("aerium_tab_switcher_mode", "0");
        if (!"0".equals(aeriumMode)) {
            if (layoutType == LayoutType.HUB) {
                if (mStackLayout != null) return mStackLayout;
            }
        }"""

    lm_c = lm_c[:idx] + routing_hooks + lm_c[idx:]
    lm_c = re.sub(
        r'if\s*\(\s*layoutType\s*==\s*LayoutType\.SIMPLE_ANIMATION\s*\)\s*\{\s*return\s+mNewTabAnimationLayout;\s*\}',
        body_insert,
        lm_c,
        count=1
    )

with open(lm_path, "w", encoding="utf-8") as f:
    f.write(lm_c)
print("[aerium] Step 6: LayoutManagerChromePhone.java patched cleanly")

# ==============================================================================
# STEP 7: INJECT STRINGS INTO ANDROID_CHROME_STRINGS.GRD
# ==============================================================================
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
    m = re.search(r"<messages[^>]*>", grd_c)
    if not m:
        print(f"[FATAL] '<messages>' tag not found in {grd_path}")
        sys.exit(1)
    idx = m.end()
    grd_c = grd_c[:idx] + new_strings + grd_c[idx:]
    with open(grd_path, "w", encoding="utf-8") as f:
        f.write(grd_c)
    print("[aerium] Step 7: Strings injected into android_chrome_strings.grd")

# ==============================================================================
# STEP 8: PREFERENCE ARRAYS INJECTION
# ==============================================================================
primary_res_xml = None
for candidate in glob.glob("**/chrome/android/java/res/values/values.xml", recursive=True):
    if "out" not in candidate and "third_party" not in candidate:
        primary_res_xml = candidate
        break

if not primary_res_xml:
    print("[FATAL] Could not find primary values.xml")
    sys.exit(1)

with open(primary_res_xml, "r", encoding="utf-8") as f:
    res_c = f.read()

res_c = re.sub(
    r'\s*<!-- Aerium Tab Switcher Preference Arrays -->[\s\S]*?<string-array name="aerium_tab_switcher_values">[\s\S]*?</string-array>',
    "",
    res_c
)
res_c = re.sub(r'\s*<string-array name="aerium_tab_switcher_entries">[\s\S]*?</string-array>', "", res_c)
res_c = re.sub(r'\s*<string-array name="aerium_tab_switcher_values">[\s\S]*?</string-array>', "", res_c)

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
with open(primary_res_xml, "w", encoding="utf-8") as f:
    f.write(res_c)
print(f"[aerium] Step 8: Preference arrays injected atomically into {primary_res_xml}")

# ==============================================================================
# STEP 9: SETTINGS XML INJECTION
# ==============================================================================
settings_path = find_file("tabs_settings.xml", path_hint=os.path.join("res", "xml"))
with open(settings_path, "r", encoding="utf-8") as f:
    set_c = f.read()

set_c = re.sub(r'<ListPreference[^>]*android:key="aerium_tab_switcher_mode"[\s\S]*?/>\s*', "", set_c)

if 'xmlns:app="http://schemas.android.com/apk/res-auto"' not in set_c:
    set_c = set_c.replace("<PreferenceScreen", '<PreferenceScreen xmlns:app="http://schemas.android.com/apk/res-auto"', 1)

pref_item = """
    <ListPreference
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
print(f"[aerium] Step 9: Injected ListPreference atomically into {settings_path}")

# ==============================================================================
# STEP 10: HOOK PREFERENCE LISTENER IN TABSSETTINGS.JAVA
# ==============================================================================
tabs_settings_java = find_file("TabsSettings.java", path_hint=os.path.join("tasks", "tab_management"))
with open(tabs_settings_java, "r", encoding="utf-8") as f:
    ts_c = f.read()

if "aerium_tab_switcher_mode" not in ts_c:
    if "import androidx.preference.ListPreference;" not in ts_c:
        import_anchor = "import androidx.preference.Preference;"
        if import_anchor in ts_c:
            ts_c = ts_c.replace(
                import_anchor,
                "import androidx.preference.Preference;\nimport androidx.preference.ListPreference;",
                1
            )

    pref_anchor = "SettingsUtils.addPreferencesFromResource(this, R.xml.tabs_settings);"
    if pref_anchor not in ts_c:
        print(f"[FATAL] Anchor '{pref_anchor}' not found in {tabs_settings_java}")
        sys.exit(1)

    sync_code = """SettingsUtils.addPreferencesFromResource(this, R.xml.tabs_settings);

        androidx.preference.ListPreference aeriumPref =
                (androidx.preference.ListPreference) findPreference("aerium_tab_switcher_mode");
        if (aeriumPref != null) {
            aeriumPref.setSummaryProvider(
                    androidx.preference.ListPreference.SimpleSummaryProvider.getInstance());
            aeriumPref.setOnPreferenceChangeListener((preference, newValue) -> {
                org.chromium.base.ContextUtils.getAppSharedPreferences().edit()
                        .putString("aerium_tab_switcher_mode", (String) newValue).apply();
                return true;
            });
        }"""

    ts_c = ts_c.replace(pref_anchor, sync_code, 1)
    with open(tabs_settings_java, "w", encoding="utf-8") as f:
        f.write(ts_c)
    print("[aerium] Step 10: Hooked preference listener into TabsSettings.java")

# ==============================================================================
# STEP 11: TABUIFEATUREUTILITIES.JAVA HELPER
# ==============================================================================
util_path = find_file("TabUiFeatureUtilities.java", path_hint=os.path.join("tasks", "tab_management"))
with open(util_path, "r", encoding="utf-8") as f:
    u_c = f.read()

if "getAeriumTabSwitcherMode" not in u_c:
    match = re.search(r"public\s+static\s+boolean\s+doesOemSupportDragToCreateInstance\(\)\s*\{[\s\S]*?\}", u_c)
    if not match:
        print(f"[FATAL] Anchor method doesOemSupportDragToCreateInstance not found in {util_path}")
        sys.exit(1)

    idx = match.end()
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
    }"""

    u_c = u_c[:idx] + methods + u_c[idx:]
    with open(util_path, "w", encoding="utf-8") as f:
        f.write(u_c)
    print("[aerium] Step 11: TabUiFeatureUtilities patched with mode helpers")

# ==============================================================================
# STEP 12: SANITIZE TabListCoordinator.java (Fix final variable reassignment)
# ==============================================================================
tlc_path = find_file("TabListCoordinator.java", path_hint=os.path.join("tasks", "tab_management"))
with open(tlc_path, "r", encoding="utf-8") as f:
    tlc_c = f.read()

if "final Size newDefaultSize" in tlc_c:
    tlc_c = tlc_c.replace("final Size newDefaultSize", "Size newDefaultSize")
    with open(tlc_path, "w", encoding="utf-8") as f:
        f.write(tlc_c)
    print("[aerium] Step 12: Stripped final modifier from newDefaultSize in TabListCoordinator.java")
else:
    print("[aerium] Step 12: TabListCoordinator.java newDefaultSize already non-final or pristine")

print("\n[aerium] All steps verified and completed cleanly.")
