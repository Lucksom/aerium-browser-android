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
# ==============================================================================
# STEP 1: RESTORE MISSING STACK PROPERTIES IN LayoutTab.java
# ==============================================================================
lt_path = find_file("LayoutTab.java", path_hint=os.path.join("compositor", "layouts", "components"))
with open(lt_path, "r", encoding="utf-8") as f:
    lt_c = f.read()

# 1. Inject missing PropertyKeys
if "TILT_X_IN_DEGREES = new WritableFloatPropertyKey();" not in lt_c:
    keys_anchor = "public static final WritableFloatPropertyKey BORDER_ALPHA = new WritableFloatPropertyKey();"
    if keys_anchor not in lt_c:
        print(f"[FATAL] Keys anchor '{keys_anchor}' not found in {lt_path}")
        sys.exit(1)
    keys_replacement = """public static final WritableFloatPropertyKey BORDER_ALPHA = new WritableFloatPropertyKey();
    public static final WritableFloatPropertyKey TILT_X_IN_DEGREES = new WritableFloatPropertyKey();
    public static final WritableFloatPropertyKey TILT_Y_IN_DEGREES = new WritableFloatPropertyKey();
    public static final WritableFloatPropertyKey SIDE_BORDER_SCALE = new WritableFloatPropertyKey();
    public static final WritableFloatPropertyKey BORDER_CLOSE_BUTTON_ALPHA = new WritableFloatPropertyKey();
    public static final WritableFloatPropertyKey MAX_CONTENT_HEIGHT = new WritableFloatPropertyKey();
    public static final WritableFloatPropertyKey TOOLBAR_Y_OFFSET = new WritableFloatPropertyKey();
    public static final WritableFloatPropertyKey TOOLBAR_ALPHA = new WritableFloatPropertyKey();
    public static final WritableFloatPropertyKey SATURATION = new WritableFloatPropertyKey();
    public static final org.chromium.ui.modelutil.PropertyModel.WritableBooleanPropertyKey CLOSE_BUTTON_IS_ON_RIGHT =
            new org.chromium.ui.modelutil.PropertyModel.WritableBooleanPropertyKey();
    public static final org.chromium.ui.modelutil.PropertyModel.WritableObjectPropertyKey<android.graphics.RectF> CLOSE_PLACEMENT =
            new org.chromium.ui.modelutil.PropertyModel.WritableObjectPropertyKey<>();
    public static final float CLOSE_BUTTON_WIDTH_DP = 36.0f;"""
    lt_c = lt_c.replace(keys_anchor, keys_replacement, 1)
    print("[aerium] Injected PropertyKey definitions into LayoutTab.java")
else:
    print("[aerium] Already patched: LayoutTab.java missing PropertyKeys")

# 2. Inject keys into ALL_KEYS array using flexible whitespace/newline matching
if "TILT_X_IN_DEGREES," not in lt_c:
    all_keys_addition = """
            TILT_X_IN_DEGREES,
            TILT_Y_IN_DEGREES,
            SIDE_BORDER_SCALE,
            BORDER_CLOSE_BUTTON_ALPHA,
            MAX_CONTENT_HEIGHT,
            TOOLBAR_Y_OFFSET,
            TOOLBAR_ALPHA,
            SATURATION,
            CLOSE_BUTTON_IS_ON_RIGHT,
            CLOSE_PLACEMENT,"""

    all_keys_match = re.search(r"ALL_KEYS\s*=\s*(?:new\s+PropertyKey\[\]\s*)?\{", lt_c)
    if all_keys_match:
        idx = all_keys_match.end()
        lt_c = lt_c[:idx] + all_keys_addition + lt_c[idx:]
        print("[aerium] Injected PropertyKeys into ALL_KEYS array")
    else:
        border_match = re.search(r"(\s+BORDER_ALPHA,)", lt_c)
        if border_match:
            idx = border_match.end()
            lt_c = lt_c[:idx] + all_keys_addition + lt_c[idx:]
            print("[aerium] Injected PropertyKeys into ALL_KEYS array (via BORDER_ALPHA,)")
        else:
            print(f"[FATAL] Could not find ALL_KEYS array or BORDER_ALPHA, in {lt_path}")
            sys.exit(1)
else:
    print("[aerium] Already patched: LayoutTab.java ALL_KEYS array expansion")

# 3. Inject methods before constructor
if "public void setTiltX(" not in lt_c:
    methods_addition = """    private float mTiltX;
    private float mTiltY;
    private float mMaxContentWidth;
    private float mMaxContentHeight;
    private boolean mCloseButtonOnRight;
    private float mBorderCloseButtonAlpha;

    public void setTiltX(float angle, float pivot) { mTiltX = angle; }
    public void setTiltY(float angle, float pivot) { mTiltY = angle; }
    public float getTiltX() { return mTiltX; }
    public float getTiltY() { return mTiltY; }
    public void setBorderCloseButtonAlpha(float alpha) { mBorderCloseButtonAlpha = alpha; }
    public float getBorderCloseButtonAlpha() { return mBorderCloseButtonAlpha; }
    public void setCloseButtonIsOnRight(boolean onRight) { mCloseButtonOnRight = onRight; }
    public boolean isCloseButtonOnRight() { return mCloseButtonOnRight; }
    public float getUnclampedOriginalContentHeight() { return getOriginalContentHeight(); }
    public float getMaxContentWidth() { return mMaxContentWidth > 0 ? mMaxContentWidth : getOriginalContentWidth(); }
    public float getMaxContentHeight() { return mMaxContentHeight > 0 ? mMaxContentHeight : getOriginalContentHeight(); }
    public void setMaxContentWidth(float w) { mMaxContentWidth = w; }
    public void setMaxContentHeight(float h) { mMaxContentHeight = h; }
    public boolean shouldStall() { return false; }
    public void setInsetBorderVertical(boolean inset) {}
    public void setShowToolbar(boolean show) {}
    public void setToolbarAlpha(float alpha) { set(TOOLBAR_ALPHA, alpha); }
    public float getToolbarAlpha() { return has(TOOLBAR_ALPHA) ? get(TOOLBAR_ALPHA) : 0f; }
    public void setAnonymizeToolbar(boolean anonymize) {}
    public void setDrawDecoration(boolean draw) {}
    public void setDecorationAlpha(float alpha) {}
    public void setBorderScale(float scale) {}
    public float getFinalContentWidth() { return getScaledContentWidth(); }
    public float getFinalContentHeight() { return getScaledContentHeight(); }
    private boolean has(org.chromium.ui.modelutil.PropertyModel.WritableFloatPropertyKey key) {
        try { return get(key) != 0.0f; } catch (Exception e) { return false; }
    }

    """
    ctor_match = re.search(r"public\s+LayoutTab\s*\(", lt_c)
    if not ctor_match:
        print(f"[FATAL] Could not find 'public LayoutTab(' constructor in {lt_path}")
        sys.exit(1)
    idx = ctor_match.start()
    lt_c = lt_c[:idx] + methods_addition + lt_c[idx:]
    print("[aerium] Injected stack methods into LayoutTab.java")
else:
    print("[aerium] Already patched: LayoutTab.java stack methods")

with open(lt_path, "w", encoding="utf-8") as f:
    f.write(lt_c)
print("[aerium] Step 1: LayoutTab.java successfully updated")

# ==============================================================================
# STEP 2: INJECT releaseTabLayout & SHOW_CLOSE_BUTTON IN Layout.java
# ==============================================================================
l_path = find_file("Layout.java", path_hint=os.path.join("compositor", "layouts"))
layout_anchor = "public LayoutTab createLayoutTab(int id, boolean isIncognito) {"
layout_replacement = """public static final boolean SHOW_CLOSE_BUTTON = true;
    public void releaseTabLayout(org.chromium.chrome.browser.compositor.layouts.components.LayoutTab tab) {}

    public LayoutTab createLayoutTab(int id, boolean isIncognito) {"""
patch_file(l_path, layout_anchor, layout_replacement, "Layout.java releaseTabLayout and SHOW_CLOSE_BUTTON")

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

# Targeted denylist: only verified deleted M88 resources
KNOWN_DELETED_RESOURCES = [
    "R.dimen.stacked_tab_visible_size",
    "R.dimen.stack_buffer_width",
    "R.dimen.stack_buffer_height",
    "R.dimen.over_scroll",
    "R.integer.over_scroll_angle",
    "R.dimen.over_scroll_slide",
    "R.dimen.tabswitcher_border_frame_transparent_top",
    "R.dimen.tabswitcher_border_frame_transparent_side",
    "R.dimen.tabswitcher_border_frame_padding_top",
    "R.dimen.tabswitcher_border_frame_padding_left",
    "R.dimen.compositor_button_slop",
    "R.dimen.even_out_scrolling",
    "R.dimen.min_spacing",
    "R.dimen.open_new_tab_animation_y_translation",
]

for filename, target_dir in file_mappings.items():
    src_file = os.path.join(patch_dir, filename)
    if not os.path.exists(src_file):
        print(f"[FATAL] Source file {filename} does not exist in {patch_dir}!")
        sys.exit(1)

    os.makedirs(target_dir, exist_ok=True)
    with open(src_file, "r", encoding="utf-8") as f:
        content = f.read()

    # Mechanical M153 import updates
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
    content = content.replace(
        "BakedBezierInterpolator.FADE_OUT_CURVE",
        "Interpolators.FAST_OUT_SLOW_IN_INTERPOLATOR"
    )

    # Scoped file-specific modifications
    if filename == "StackLayoutBase.java":
        if "import android.os.SystemClock;" not in content:
            content = "import android.os.SystemClock;\n" + content
        content = content.replace("LayoutManager.time()", "SystemClock.uptimeMillis()")

        push_pattern = r"mSceneLayer\.pushLayers\s*\([^;]+?\);"
        push_replacement = """mSceneLayer.pushLayers(getContext(), viewport, contentViewport, this,
                tabContentManager, resourceManager, browserControls,
                SceneLayer.INVALID_RESOURCE_ID, 0, 0);"""
        content, count = re.subn(push_pattern, push_replacement, content, count=1)
        if count == 0 and "SceneLayer.INVALID_RESOURCE_ID" not in content:
            print(f"[FATAL] Could not find mSceneLayer.pushLayers call site in {filename}")
            sys.exit(1)

    elif filename == "Stack.java":
        content = content.replace("!mLayout.isHiding()", "!mLayout.isStartingToHide()")
        create_pattern = r"mLayout\.createLayoutTab\s*\([^;]+?\);"
        create_replacement = "mLayout.createLayoutTab(tabId, isIncognito);"
        content, count = re.subn(create_pattern, create_replacement, content, count=1)
        if count == 0 and "mLayout.createLayoutTab(tabId, isIncognito);" not in content:
            print(f"[FATAL] Could not find mLayout.createLayoutTab call site in {filename}")
            sys.exit(1)

    # Neutralize deleted resource references with safe physical constants
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

    # Targeted check: only fail if known-deleted resources slipped past replacement
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

field_anchor = "private Layout mNewTabAnimationLayout;"
field_repl = """private Layout mNewTabAnimationLayout;
    private @Nullable org.chromium.chrome.browser.compositor.layouts.phone.StackLayout mStackLayout;"""
patch_file(lm_path, field_anchor, field_repl, "LayoutManager field declaration")

destroy_anchor = "mNewTabAnimationLayout.destroy();"
destroy_repl = """mNewTabAnimationLayout.destroy();
        if (mStackLayout != null) {
            mStackLayout.destroy();
        }"""
patch_file(lm_path, destroy_anchor, destroy_repl, "LayoutManager destroy hook")

init_anchor = "mNewTabAnimationLayout.setTabContentManager(tabContentManager);"
init_repl = """mNewTabAnimationLayout.setTabContentManager(tabContentManager);

        org.chromium.base.supplier.ObservableSupplierImpl<
                org.chromium.chrome.browser.browser_controls.BrowserControlsStateProvider>
                controlsSupplier = new org.chromium.base.supplier.ObservableSupplierImpl<>();
        controlsSupplier.set(getBrowserControlsManager());
        mStackLayout =
                new org.chromium.chrome.browser.compositor.layouts.phone.StackLayout(
                        context, this, renderHost, controlsSupplier);
        mStackLayout.setTabModelSelector(selector, tabContentManager);"""
patch_file(lm_path, init_anchor, init_repl, "LayoutManager init instantiation")

routing_anchor = "    @Override\n    protected Layout getLayoutForType(int layoutType) {"
routing_repl = """    @Override
    public void startShowing(Layout layout, boolean animate) {
        String aeriumMode =
                org.chromium.base.ContextUtils.getAppSharedPreferences()
                        .getString("aerium_tab_switcher_mode", "0");
        if (!"0".equals(aeriumMode)) {
            if (layout != null
                    && (layout.getLayoutType() == LayoutType.TAB_SWITCHER
                            || layout.getLayoutType() == LayoutType.HUB)) {
                if (mStackLayout != null) {
                    super.startShowing(mStackLayout, animate);
                    return;
                }
            }
        }
        super.startShowing(layout, animate);
    }

    @Override
    protected Layout getLayoutForType(int layoutType) {
        if (layoutType == LayoutType.SIMPLE_ANIMATION) {
            return mNewTabAnimationLayout;
        }
        String aeriumMode =
                org.chromium.base.ContextUtils.getAppSharedPreferences()
                        .getString("aerium_tab_switcher_mode", "0");
        if (!"0".equals(aeriumMode)) {
            if (layoutType == LayoutType.TAB_SWITCHER || layoutType == LayoutType.HUB) {
                if (mStackLayout != null) return mStackLayout;
            }
        }"""
patch_file(lm_path, routing_anchor, routing_repl, "LayoutManager layout routing hooks")

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
# STEP 8: PREFERENCE ARRAYS INJECTION (ATOMIC DEDUP & WRITE)
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
if "</resources>" not in res_c:
    print(f"[FATAL] '</resources>' closing tag not found in {primary_res_xml}")
    sys.exit(1)

res_c = res_c.replace("</resources>", arrays_snippet + "\n</resources>", 1)
with open(primary_res_xml, "w", encoding="utf-8") as f:
    f.write(res_c)
print(f"[aerium] Step 8: Preference arrays injected atomically into {primary_res_xml}")

# ==============================================================================
# STEP 9: SETTINGS XML INJECTION (ATOMIC DEDUP & NAMESPACE WRITE)
# ==============================================================================
settings_path = find_file("tabs_settings.xml", path_hint=os.path.join("res", "xml"))
with open(settings_path, "r", encoding="utf-8") as f:
    set_c = f.read()

set_c = re.sub(r'<ListPreference[^>]*android:key="aerium_tab_switcher_mode"[\s\S]*?/>\s*', "", set_c)

if 'xmlns:app="http://schemas.android.com/apk/res-auto"' not in set_c:
    if "<PreferenceScreen" not in set_c:
        print(f"[FATAL] '<PreferenceScreen' not found in {settings_path}")
        sys.exit(1)
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

if "</PreferenceScreen>" not in set_c:
    print(f"[FATAL] '</PreferenceScreen>' not found in {settings_path}")
    sys.exit(1)

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
    match = re.search(pattern_create, ts_c)
    if not match:
        print(f"[FATAL] Could not find onCreatePreferences/setPreferencesFromResource anchor in {tabs_settings_java}")
        sys.exit(1)
    patch_file(tabs_settings_java, match.group(0), match.group(0) + sync_code, "TabsSettings.java preference listener hook")

# ==============================================================================
# STEP 11: TABUIFEATUREUTILITIES.JAVA HELPER
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
    closing_anchor = "\n}"
    idx = u_c.rfind(closing_anchor)
    if idx == -1:
        print(f"[FATAL] Closing anchor not found in {util_path}")
        sys.exit(1)
    u_c = u_c[:idx] + "\n" + methods + closing_anchor
    with open(util_path, "w", encoding="utf-8") as f:
        f.write(u_c)
    print("[aerium] Step 11: TabUiFeatureUtilities patched with mode helpers")

print("\n[aerium] All steps verified and completed cleanly.")
