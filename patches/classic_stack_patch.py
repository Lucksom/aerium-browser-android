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

# --- 2. RESTORE AND PATCH TABLISTCOORDINATOR.JAVA WITHOUT REGEX ---
coord_path = find_file("TabListCoordinator.java", path_hint=os.path.join("tasks", "tab_management"))
with open(coord_path, "r", encoding="utf-8") as f:
    c = f.read()

# Balance check: if braces are missing, restore the closing brace!
open_braces = c.count("{")
close_braces = c.count("}")
if open_braces > close_braces:
    missing = open_braces - close_braces
    print(f"[aerium] Detected {missing} missing closing brace(s) in TabListCoordinator. Restoring!")
    c = c.rstrip() + ("\n}\n" * missing)

# Clean out any old broken line literal (NO REGEX)
bad_line = "newDefaultSize = new Size(mRecyclerView.getWidth(), classicCardHeightPx);"
if bad_line in c:
    c = c.replace(bad_line, "")

# Literal replacement for card size (NO REGEX)
old_target = "mMediator.setDefaultGridCardSize(newDefaultSize);"
clean_size_code = """if (TabUiFeatureUtilities.isVerticalStackSelected()) {
            int w = (newDefaultSize != null && newDefaultSize.getWidth() > 0) ? newDefaultSize.getWidth() : mRecyclerView.getWidth();
            if (w <= 0) w = 1080;
            int h = (mRecyclerView.getHeight() > 0) ? (int)(mRecyclerView.getHeight() * 0.70f) : (int)(w * 1.45f);
            mMediator.setDefaultGridCardSize(new Size(w, h));
        } else {
            mMediator.setDefaultGridCardSize(newDefaultSize);
        }"""

if "isVerticalStackSelected" not in c and old_target in c:
    c = c.replace(old_target, clean_size_code, 1)

# Literal replacement for setLayoutManager (NO REGEX)
old_lm = "mRecyclerView.setLayoutManager(gridLayoutManager);"
clean_lm_code = """if (TabUiFeatureUtilities.isVerticalStackSelected()) {
            ClassicStackLayoutManager stackManager = new ClassicStackLayoutManager(mRecyclerView.getContext());
            mRecyclerView.setLayoutManager(stackManager);
            mRecyclerView.setClipChildren(false);
            mRecyclerView.setClipToPadding(false);
        } else {
            mRecyclerView.setLayoutManager(gridLayoutManager);
        }"""

if "ClassicStackLayoutManager stackManager" not in c and old_lm in c:
    c = c.replace(old_lm, clean_lm_code, 1)

# Final brace verification
open_braces = c.count("{")
close_braces = c.count("}")
if open_braces != close_braces:
    diff = open_braces - close_braces
    if diff > 0:
        c = c.rstrip() + ("\n}\n" * diff)

with open(coord_path, "w", encoding="utf-8") as f:
    f.write(c)
print(f"[aerium] TabListCoordinator saved with balanced braces ({open_braces} open, {c.count('}')} close).")

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

# --- 4. Step C: Preference Arrays injection (DEDUPLICATE ACROSS ALL MODULES) ---
# Delete any duplicate arrays from tab_ui or any other module
for xml_path in (
    glob.glob("**/values.xml", recursive=True)
    + glob.glob("**/arrays.xml", recursive=True)
    + glob.glob("**/strings.xml", recursive=True)
):
  if "out" in xml_path or "third_party" in xml_path:
    continue
  # If it's NOT the primary chrome/android/java/res/values directory, strip the arrays!
  if "chrome/android/java/res/values" not in xml_path:
    try:
      with open(xml_path, "r", encoding="utf-8") as fp:
        content = fp.read()
      if "aerium_tab_switcher_entries" in content:
        content = re.sub(
            r"<!-- Aerium Tab Switcher Preference Arrays"
            r" -->[\s\S]*?</string-array>",
            "",
            content,
        )
        content = re.sub(
            r'<string-array name="aerium_tab_switcher_entries">[\s\S]*?</string-array>',
            "",
            content,
        )
        content = re.sub(
            r'<string-array name="aerium_tab_switcher_values">[\s\S]*?</string-array>',
            "",
            content,
        )
        with open(xml_path, "w", encoding="utf-8") as fp:
          fp.write(content)
        print(f"[aerium] Stripped duplicate array from {xml_path}")
    except Exception:
      pass

# Now inject ONCE into chrome/android/java/res/values/values.xml
primary_res_xml = None
for candidate in glob.glob(
    "**/chrome/android/java/res/values/values.xml", recursive=True
):
  if "out" not in candidate and "third_party" not in candidate:
    primary_res_xml = candidate
    break

if primary_res_xml:
  with open(primary_res_xml, "r", encoding="utf-8") as f:
    res_c = f.read()

  # Clean any malformed arrays first
  res_c = re.sub(
      r'<string-array name="aerium_tab_switcher_entries">[\s\S]*?</string-array>',
      "",
      res_c,
  )
  res_c = re.sub(
      r'<string-array name="aerium_tab_switcher_values">[\s\S]*?</string-array>',
      "",
      res_c,
  )

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
  print(f"[aerium] Injected arrays uniquely into {primary_res_xml}")

# --- 5. Step D: Settings XML injection (Use ListPreference - fixes ClassNotFoundException) ---
settings_path = find_file(
    "tabs_settings.xml", path_hint=os.path.join("res", "xml")
)
with open(settings_path, "r", encoding="utf-8") as f:
  set_c = f.read()

# Remove the broken ChromeBaseListPreference that caused the crash
set_c = re.sub(
    r"<org\.chromium\.components\.browser_ui\.settings\.ChromeBaseListPreference[\s\S]*?/>",
    "",
    set_c,
)
set_c = re.sub(
    r'<ListPreference[^>]*android:key="aerium_tab_switcher_mode"[\s\S]*?/>',
    "",
    set_c,
)

# Use standard androidx ListPreference
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
  print(
      "[aerium] Replaced ChromeBaseListPreference with standard ListPreference"
      " in tabs_settings.xml"
  )

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