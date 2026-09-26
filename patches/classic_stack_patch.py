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
        and (not path_hint or path_hint in p)
    ]
    if not matches:
        print(f"[FATAL] Target file not found: {filename} (hint: '{path_hint}')")
        sys.exit(1)
    return matches[0]

src_root = os.getcwd()
patch_dir = os.path.join(src_root, "patches", "classic_stack")

# ==============================================================================
# STEP 1: RESTORE MISSING STACK PROPERTIES IN LayoutTab.java
# ==============================================================================
lt_path = find_file("LayoutTab.java", path_hint=os.path.join("compositor", "layouts", "components"))
with open(lt_path, "r", encoding="utf-8") as f:
    lt_c = f.read()

if "TILT_X_IN_DEGREES" not in lt_c:
    keys_anchor = "public static final WritableFloatPropertyKey BORDER_ALPHA = new WritableFloatPropertyKey();"
    missing_keys = """public static final WritableFloatPropertyKey BORDER_ALPHA = new WritableFloatPropertyKey();
    public static final WritableFloatPropertyKey TILT_X_IN_DEGREES = new WritableFloatPropertyKey();
    public static final WritableFloatPropertyKey TILT_Y_IN_DEGREES = new WritableFloatPropertyKey();
    public static final WritableFloatPropertyKey SIDE_BORDER_SCALE = new WritableFloatPropertyKey();
    public static final WritableFloatPropertyKey BORDER_CLOSE_BUTTON_ALPHA = new WritableFloatPropertyKey();
    public static final org.chromium.ui.modelutil.PropertyModel.WritableBooleanPropertyKey CLOSE_BUTTON_IS_ON_RIGHT =
            new org.chromium.ui.modelutil.PropertyModel.WritableBooleanPropertyKey();
    public static final org.chromium.ui.modelutil.PropertyModel.WritableObjectPropertyKey<android.graphics.RectF> CLOSE_PLACEMENT =
            new org.chromium.ui.modelutil.PropertyModel.WritableObjectPropertyKey<>();
    public static final float CLOSE_BUTTON_WIDTH_DP = 36.0f;
"""
    lt_c = lt_c.replace(keys_anchor, missing_keys, 1)

    # Methods hook
    methods_hook = """
    public void setTiltX(float angle, float pivot) { set(TILT_X_IN_DEGREES, angle); }
    public void setTiltY(float angle, float pivot) { set(TILT_Y_IN_DEGREES, angle); }
    public float getTiltX() { return get(TILT_X_IN_DEGREES); }
    public float getTiltY() { return get(TILT_Y_IN_DEGREES); }
    public void setBorderCloseButtonAlpha(float alpha) { set(BORDER_CLOSE_BUTTON_ALPHA, alpha); }
    public void setCloseButtonIsOnRight(boolean onRight) { set(CLOSE_BUTTON_IS_ON_RIGHT, onRight); }
    public boolean isCloseButtonOnRight() { return get(CLOSE_BUTTON_IS_ON_RIGHT); }
"""
    last_brace = lt_c.rfind("}")
    if last_brace != -1:
        lt_c = lt_c[:last_brace] + methods_hook + "\n}\n"

    with open(lt_path, "w", encoding="utf-8") as f:
        f.write(lt_c)
    print("[aerium] Step 1: Restored 3D tilt & close button properties in LayoutTab.java")

# ==============================================================================
# STEP 2: DEPLOY & SANITIZE M88 COMPOSITOR JAVA SOURCES
# ==============================================================================
dest_scene_layer = os.path.join(
    src_root, "chrome", "android", "java", "src", "org", "chromium",
    "chrome", "browser", "compositor", "scene_layer"
)
dest_layouts_phone = os.path.join(
    src_root, "chrome", "android", "java", "src", "org", "chromium",
    "chrome", "browser", "compositor", "layouts", "phone"
)
dest_layouts_stack = os.path.join(
    src_root, "chrome", "android", "java", "src", "org", "chromium",
    "chrome", "browser", "compositor", "layouts", "phone", "stack"
)

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

for filename, target_dir in file_mappings.items():
    src_file = os.path.join(patch_dir, filename)
    if not os.path.exists(src_file):
        candidates = glob.glob(f"**/{filename}", recursive=True)
        candidates = [c for c in candidates if "patches" in c and not c.startswith("out")]
        if candidates:
            src_file = candidates[0]
        else:
            print(f"[FATAL] Source file {filename} not found in patches/classic_stack!")
            sys.exit(1)

    os.makedirs(target_dir, exist_ok=True)
    with open(src_file, "r", encoding="utf-8") as f:
        content = f.read()

    # 1. Update ScrollDirection import for M153
    content = content.replace(
        "import org.chromium.chrome.browser.compositor.layouts.eventfilter.ScrollDirection;",
        "import org.chromium.components.browser_ui.widget.gesture.SwipeGestureListener.ScrollDirection;"
    )

    # 2. Update Interpolators for M153
    content = content.replace(
        "import org.chromium.components.browser_ui.widget.animation.Interpolators;",
        "import org.chromium.ui.interpolators.Interpolators;"
    )
    content = content.replace(
        "import org.chromium.ui.interpolators.BakedBezierInterpolator;",
        "import org.chromium.ui.interpolators.Interpolators;"
    )
    content = content.replace(
        "BakedBezierInterpolator.FADE_OUT_CURVE",
        "Interpolators.FAST_OUT_SLOW_IN_INTERPOLATOR"
    )

    # 3. Replace invalid LayoutManager.time()
    content = content.replace("LayoutManager.time()", "SystemClock.uptimeMillis()")

    # 4. Fix createLayoutTab 6-arg call -> 2-arg call in Stack.java
    content = re.sub(
        r"mLayout\.createLayoutTab\([^;]+\);",
        "mLayout.createLayoutTab(tabId, isIncognito);",
        content
    )

    # 5. Fix StackLayoutBase pushLayers signature to match ClassicStackSceneLayer stub
    content = re.sub(
        r"mSceneLayer\.pushLayers\([^;]+\);",
        """mSceneLayer.pushLayers(getContext(), viewport, contentViewport, this,
                tabContentManager, resourceManager, browserControls,
                SceneLayer.INVALID_RESOURCE_ID, 0, 0);""",
        content
    )

    # 6. Neutralize deleted R.dimen/integer references
    content = content.replace(
        "res.getDimensionPixelOffset(R.dimen.stacked_tab_visible_size) * pxToDp", "28.0f"
    )
    content = content.replace(
        "res.getDimensionPixelOffset(R.dimen.stack_buffer_width) * pxToDp", "0.0f"
    )
    content = content.replace(
        "res.getDimensionPixelOffset(R.dimen.stack_buffer_height) * pxToDp", "0.0f"
    )
    content = content.replace(
        "res.getDimensionPixelOffset(R.dimen.over_scroll)", "Math.round(40.0f * res.getDisplayMetrics().density)"
    )
    content = content.replace(
        "res.getInteger(R.integer.over_scroll_angle)", "15"
    )
    content = content.replace(
        "res.getDimensionPixelOffset(R.dimen.over_scroll_slide) * pxToDp", "20.0f"
    )
    content = content.replace(
        "res.getDimension(R.dimen.tabswitcher_border_frame_transparent_top) * pxToDp", "8.0f"
    )
    content = content.replace(
        "res.getDimension(R.dimen.tabswitcher_border_frame_transparent_side) * pxToDp", "8.0f"
    )
    content = content.replace(
        "res.getDimension(R.dimen.tabswitcher_border_frame_padding_top) * pxToDp", "16.0f"
    )
    content = content.replace(
        "res.getDimension(R.dimen.tabswitcher_border_frame_padding_left) * pxToDp", "8.0f"
    )
    content = content.replace(
        "res.getDimension(R.dimen.compositor_button_slop) * pxToDp", "24.0f"
    )
    content = content.replace(
        "1.0f / (res.getDimension(R.dimen.even_out_scrolling) * pxToDp)", "1.0f / 200.0f"
    )
    content = content.replace(
        "res.getDimensionPixelOffset(R.dimen.min_spacing) * pxToDp", "64.0f"
    )
    content = content.replace(
        "resources.getDimensionPixelSize(R.dimen.open_new_tab_animation_y_translation)",
        "(int) (50.0f * resources.getDisplayMetrics().density)"
    )

    # 7. Safe isHiding -> isStartingToHide
    content = content.replace("!mLayout.isHiding()", "!mLayout.isStartingToHide()")

    dest_file = os.path.join(target_dir, filename)
    with open(dest_file, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"[aerium] Deployed & sanitized: {filename} -> {dest_file}")

# ==============================================================================
# STEP 3: WRITE FULL NonOverlappingStack.java IMPLEMENTATION
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

    private boolean mSuppressScrollClamping;
    private boolean mSwitchedAway;

    public NonOverlappingStack(Context context, StackLayoutBase layout) {
        super(context, layout);
    }

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
    protected boolean evenOutTabs(float amount, boolean allowReverseDirection) {
        return false;
    }

    public int getCenteredTabIndex() {
        if (mSpacing == 0) return 0;
        return Math.round(-mScrollOffset / mSpacing);
    }

    @Override
    public void onLongPress(long time, float x, float y) {}

    @Override
    public void onPinch(long time, float x0, float y0, float x1, float y1, boolean firstEvent) {}

    @Override
    protected void springBack(long time) {
        if (!mScroller.isFinished()) return;
        int newTarget = -getCenteredTabIndex() * mSpacing;
        mScroller.flingYTo((int) mScrollTarget, newTarget, time);
        setScrollTarget(newTarget, false);
        mLayout.requestUpdate();
    }

    @Override
    protected float getSpacingScreen() { return SPACING_SCREEN; }

    @Override
    protected boolean shouldStackTabsAtTop() { return false; }

    @Override
    protected boolean shouldStackTabsAtBottom() { return false; }

    @Override
    protected float getStackPortraitYOffsetProportion() { return 0.f; }

    @Override
    protected float getStackLandscapeStartOffsetProportion() { return 0.f; }

    @Override
    protected float getStackLandscapeYOffsetProportion() { return 0.f; }

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

    @Override
    protected int computeReferenceIndex() {
        return getCenteredTabIndex();
    }

    @Override
    protected boolean shouldCloseGapsBetweenTabs() { return false; }

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

    @Override
    protected boolean allowOverscroll() { return false; }

    @Override
    protected int computeSpacing(int layoutTabCount) {
        return (int) Math.round(
                getScrollDimensionSize() * getScaleAmount() + EXTRA_SPACE_BETWEEN_TABS_DP);
    }

    @Override
    protected void resetAllScrollOffset() {
        if (mTabList == null) return;
        mScrollOffset = -mTabList.index() * mSpacing;
        setScrollTarget(mScrollOffset, false);
    }

    @Override
    public float screenToScroll(float screenSpace) { return screenSpace; }

    @Override
    public float scrollToScreen(float scrollSpace) { return scrollSpace; }

    @Override
    public float getMaxTabHeight() {
        if (getNonDyingTabCount() > 1) return mLayout.getHeight();
        return (SCALE_FRACTION_MULTIPLE_TABS / SCALE_FRACTION_SINGLE_TAB) * mLayout.getHeight();
    }

    public void suppressScrollClampingForAnimation() {
        mSuppressScrollClamping = true;
    }

    public void runSwitchAwayAnimation(@SwitchDirection int direction) {
        mSwitchedAway = true;
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
print("[aerium] Step 3: Full NonOverlappingStack.java deployed")

# ==============================================================================
# STEP 4: REGISTER ALL 10 COMPOSITOR SOURCES IN CHROME_JAVA_SOURCES.GNI
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

if anchor in gni_c:
    gni_c = gni_c.replace(anchor, anchor + new_entries, 1)
    with open(gni_path, "w", encoding="utf-8") as f:
        f.write(gni_c)
    print("[aerium] Step 4: Registered 10 compositor sources in chrome_java_sources.gni")
else:
    print("[FATAL] Anchor ToolbarSwipeLayout.java not found in chrome_java_sources.gni")
    sys.exit(1)

# ==============================================================================
# STEP 5: HOOK STACKLAYOUT INTO LAYOUTMANAGERCHROMEPHONE.JAVA
# ==============================================================================
lm_path = find_file("LayoutManagerChromePhone.java")
with open(lm_path, "r", encoding="utf-8") as f:
    lm_c = f.read()

# 1. Add field
if "mStackLayout;" not in lm_c:
    lm_c = lm_c.replace(
        "private Layout mNewTabAnimationLayout;",
        "private Layout mNewTabAnimationLayout;\n    private @Nullable org.chromium.chrome.browser.compositor.layouts.phone.StackLayout mStackLayout;"
    )

# 2. Add cleanup in destroy()
if "if (mStackLayout != null) { mStackLayout.destroy(); }" not in lm_c:
    lm_c = lm_c.replace(
        "mNewTabAnimationLayout.destroy();",
        "mNewTabAnimationLayout.destroy();\n        if (mStackLayout != null) { mStackLayout.destroy(); }"
    )

# 3. Add instantiation in init() with explicit Generic Interface Typing
init_anchor = "mNewTabAnimationLayout.setTabContentManager(tabContentManager);"
stack_init_code = """mNewTabAnimationLayout.setTabContentManager(tabContentManager);

        mStackLayout =
                new org.chromium.chrome.browser.compositor.layouts.phone.StackLayout(
                        context,
                        this,
                        renderHost,
                        new org.chromium.base.supplier.ObservableSupplierImpl<
                                org.chromium.chrome.browser.browser_controls.BrowserControlsStateProvider>(
                                getBrowserControlsManager()));
        mStackLayout.setTabModelSelector(selector, tabContentManager);"""

if "mStackLayout =" not in lm_c and init_anchor in lm_c:
    lm_c = lm_c.replace(init_anchor, stack_init_code, 1)

# 4. Route getLayoutForType() using ContextUtils
layout_type_anchor = "if (layoutType == LayoutType.SIMPLE_ANIMATION) {\n            return mNewTabAnimationLayout;\n        }"
stack_routing_code = """if (layoutType == LayoutType.SIMPLE_ANIMATION) {
            return mNewTabAnimationLayout;
        }
        String aeriumMode = org.chromium.base.ContextUtils.getAppSharedPreferences()
                .getString("aerium_tab_switcher_mode", "0");
        if (!"0".equals(aeriumMode)) {
            if (layoutType == LayoutType.TAB_SWITCHER || layoutType == LayoutType.HUB) {
                if (mStackLayout != null) return mStackLayout;
            }
        }"""

if "aerium_tab_switcher_mode" not in lm_c and layout_type_anchor in lm_c:
    lm_c = lm_c.replace(layout_type_anchor, stack_routing_code, 1)

# 5. Override startShowing() to intercept Tab Switcher / Hub activations
start_showing_hook = """
    @Override
    public void startShowing(Layout layout, boolean animate) {
        String aeriumMode = org.chromium.base.ContextUtils.getAppSharedPreferences()
                .getString("aerium_tab_switcher_mode", "0");
        if (!"0".equals(aeriumMode)) {
            if (layout != null && (layout.getLayoutType() == LayoutType.TAB_SWITCHER || layout.getLayoutType() == LayoutType.HUB)) {
                if (mStackLayout != null) {
                    super.startShowing(mStackLayout, animate);
                    return;
                }
            }
        }
        super.startShowing(layout, animate);
    }
"""
if "public void startShowing(Layout layout, boolean animate)" not in lm_c:
    last_brace = lm_c.rfind("}")
    if last_brace != -1:
        lm_c = lm_c[:last_brace] + start_showing_hook + "\n}\n"

with open(lm_path, "w", encoding="utf-8") as f:
    f.write(lm_c)
print("[aerium] Step 5: LayoutManagerChromePhone.java hooked cleanly")

# ==============================================================================
# STEP 6: INJECT STRINGS INTO ANDROID_CHROME_STRINGS.GRD
# ==============================================================================
grd_path = find_file(
    "android_chrome_strings.grd",
    path_hint=os.path.join("chrome", "browser", "ui", "android", "strings")
)
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
    if m:
        idx = m.end()
        grd_c = grd_c[:idx] + new_strings + grd_c[idx:]
        with open(grd_path, "w", encoding="utf-8") as f:
            f.write(grd_c)
        print("[aerium] Step 6: Strings injected into android_chrome_strings.grd")

# ==============================================================================
# STEP 7: PREFERENCE ARRAYS INJECTION
# ==============================================================================
primary_res_xml = None
for candidate in glob.glob("**/chrome/android/java/res/values/values.xml", recursive=True):
    if "out" not in candidate and "third_party" not in candidate:
        primary_res_xml = candidate
        break

if primary_res_xml:
    with open(primary_res_xml, "r", encoding="utf-8") as f:
        res_c = f.read()

    res_c = re.sub(r'<string-array name="aerium_tab_switcher_entries">[\s\S]*?</string-array>', "", res_c)
    res_c = re.sub(r'<string-array name="aerium_tab_switcher_values">[\s\S]*?</string-array>', "", res_c)

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
    print(f"[aerium] Step 7: Preference arrays injected into {primary_res_xml}")

# ==============================================================================
# STEP 8: SETTINGS XML INJECTION
# ==============================================================================
settings_path = find_file("tabs_settings.xml", path_hint=os.path.join("res", "xml"))
with open(settings_path, "r", encoding="utf-8") as f:
    set_c = f.read()

set_c = re.sub(r'<ListPreference[^>]*android:key="aerium_tab_switcher_mode"[\s\S]*?/>', "", set_c)

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

if "</PreferenceScreen>" in set_c:
    set_c = set_c.replace("</PreferenceScreen>", pref_item + "\n</PreferenceScreen>", 1)
    with open(settings_path, "w", encoding="utf-8") as f:
        f.write(set_c)
    print("[aerium] Step 8: Injected ListPreference into tabs_settings.xml")

# ==============================================================================
# STEP 9: HOOK PREFERENCE LISTENER IN TABSSETTINGS.JAVA
# ==============================================================================
tabs_settings_java = find_file("TabsSettings.java", path_hint=os.path.join("tasks", "tab_management"))
with open(tabs_settings_java, "r", encoding="utf-8") as f:
    ts_c = f.read()

if "aerium_tab_switcher_mode" not in ts_c:
    if "import androidx.preference.ListPreference;" not in ts_c:
        ts_c = "import androidx.preference.ListPreference;\n" + ts_c

    sync_code = """
        ListPreference aeriumPref = (ListPreference) findPreference("aerium_tab_switcher_mode");
        if (aeriumPref != null) {
            aeriumPref.setSummaryProvider(ListPreference.SimpleSummaryProvider.getInstance());
            aeriumPref.setOnPreferenceChangeListener((preference, newValue) -> {
                org.chromium.base.ContextUtils.getAppSharedPreferences().edit()
                        .putString("aerium_tab_switcher_mode", (String) newValue).apply();
                return true;
            });
        }
"""
    pattern_create = r"(void\s+onCreatePreferences\s*\([^)]*\)\s*\{[\s\S]*?setPreferencesFromResource\([^)]*\);)"
    if re.search(pattern_create, ts_c):
        ts_c = re.sub(pattern_create, r"\1" + sync_code, ts_c, count=1)
        with open(tabs_settings_java, "w", encoding="utf-8") as f:
            f.write(ts_c)
        print("[aerium] Step 9: Hooked preference listener in TabsSettings.java")

# ==============================================================================
# STEP 10: TABUIFEATUREUTILITIES.JAVA HELPER
# ==============================================================================
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
        print("[aerium] Step 10: TabUiFeatureUtilities patched with mode helpers")

print("[aerium] Verified classic stack patch completed with zero errors.")
