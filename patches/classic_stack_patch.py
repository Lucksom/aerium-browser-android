#!/usr/bin/env python3
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

# --- 1. REVERT M88 ENTRIES FROM CHROME_JAVA_SOURCES.GNI (IF PRESENT) ---
gni_path = find_file("chrome_java_sources.gni")
with open(gni_path, "r", encoding="utf-8") as f:
    gni_c = f.read()

m88_entries = [
    '"//chrome/android/java/src/org/chromium/chrome/browser/compositor/layouts/phone/StackLayoutBase.java",\n',
    '"//chrome/android/java/src/org/chromium/chrome/browser/compositor/layouts/phone/StackLayout.java",\n',
    '"//chrome/android/java/src/org/chromium/chrome/browser/compositor/layouts/phone/stack/Stack.java",\n',
    '"//chrome/android/java/src/org/chromium/chrome/browser/compositor/layouts/phone/stack/StackTab.java",\n',
    '"//chrome/android/java/src/org/chromium/chrome/browser/compositor/layouts/phone/stack/StackAnimation.java",\n',
    '"//chrome/android/java/src/org/chromium/chrome/browser/compositor/layouts/phone/stack/OverlappingStack.java",\n',
    '"//chrome/android/java/src/org/chromium/chrome/browser/compositor/scene_layer/ClassicStackSceneLayer.java",\n',
]
for entry in m88_entries:
    gni_c = gni_c.replace("  " + entry, "").replace(entry, "")

with open(gni_path, "w", encoding="utf-8") as f:
    f.write(gni_c)
print("[aerium] Cleaned M88 entries from chrome_java_sources.gni")

# --- 2. SURGICALLY HEAL & INTEGRATE TABLISTCOORDINATOR.JAVA ---
coord_path = find_file("TabListCoordinator.java", path_hint=os.path.join("tasks", "tab_management"))
with open(coord_path, "r", encoding="utf-8") as f:
    c = f.read()

# 2a. Directly remove the illegal final variable assignment that broke line 766
bad_line = "newDefaultSize = new Size(mRecyclerView.getWidth(), classicCardHeightPx);"
if bad_line in c:
    print("[aerium] Removing illegal newDefaultSize assignment!")
    c = c.replace(bad_line, "")

# 2b. Clean any old broken snippet or early return
clean_replacement = """if (TabUiFeatureUtilities.isVerticalStackSelected()) {
            int w = (newDefaultSize != null && newDefaultSize.getWidth() > 0) ? newDefaultSize.getWidth() : mRecyclerView.getWidth();
            if (w <= 0) w = 1080;
            int h = (mRecyclerView.getHeight() > 0) ? (int)(mRecyclerView.getHeight() * 0.70f) : (int)(w * 1.45f);
            mMediator.setDefaultGridCardSize(new Size(w, h));
        } else {
            mMediator.setDefaultGridCardSize(newDefaultSize);
        }"""

standard_call = "mMediator.setDefaultGridCardSize(newDefaultSize);"

if "isVerticalStackSelected" in c and "mMediator.setDefaultGridCardSize" in c:
    pattern_existing = r'if \(TabUiFeatureUtilities\.isVerticalStackSelected\(\)\)[\s\S]*?mMediator\.setDefaultGridCardSize\(newDefaultSize\);\s*\}'
    c = re.sub(pattern_existing, clean_replacement.strip(), c)
elif standard_call in c:
    c = c.replace(standard_call, clean_replacement, 1)

# 2c. layoutType: Disable UI grouping if Mode 2 is selected
if "isTabGroupDisabledForVerticalStack" not in c:
    pattern_layout = r'int\s+layoutType\s*=\s*actionOnRelatedTabs\s*\?\s*TabListLayoutType\.GROUPED\s*:\s*TabListLayoutType\.FLAT\s*;'
    repl_layout = 'int layoutType = (actionOnRelatedTabs && !TabUiFeatureUtilities.isTabGroupDisabledForVerticalStack()) ? TabListLayoutType.GROUPED : TabListLayoutType.FLAT;'
    c = re.sub(pattern_layout, repl_layout, c, count=1)

# 2d. setLayoutManager: Attach ClassicStackLayoutManager
if "ClassicStackLayoutManager stackManager" not in c:
    pattern_rv = r'mRecyclerView\.setLayoutManager\(\s*gridLayoutManager\s*\);'
    repl_rv = """if (TabUiFeatureUtilities.isVerticalStackSelected()) {
            ClassicStackLayoutManager stackManager = new ClassicStackLayoutManager(mRecyclerView.getContext());
            mRecyclerView.setLayoutManager(stackManager);
            mRecyclerView.setClipChildren(false);
            mRecyclerView.setClipToPadding(false);
        } else {
            mRecyclerView.setLayoutManager(gridLayoutManager);
        }"""
    c = re.sub(pattern_rv, repl_rv, c, count=1)

with open(coord_path, "w", encoding="utf-8") as f:
    f.write(c)
print("[aerium] TabListCoordinator.java cleanly integrated.")

# --- 3. Step B: Strings injection in android_chrome_strings.grd ---
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
        print("[aerium] Strings injected into android_chrome_strings.grd")

# --- 4. Step C: Preference Arrays injection (Chrome values.xml only) ---
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
        print(f"[aerium] Arrays injected into {target_res_xml}")

# --- 5. Step D: Settings XML injection (Tabs & Tab Groups) ---
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

# --- 6. Step E: TabUiFeatureUtilities.java mode helper ---
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

# --- 7. Step F: ClassicStackLayoutManager.java ---
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

# --- 8. Step H: TabListMediator (1 card per row for vertical stack) ---
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

print("[aerium] Classic Stack Patch executed successfully.")
