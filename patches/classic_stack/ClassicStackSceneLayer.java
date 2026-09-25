// Copyright 2026 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package org.chromium.chrome.browser.compositor.scene_layer;

import android.content.Context;
import android.graphics.RectF;

import org.chromium.chrome.browser.browser_controls.BrowserControlsStateProvider;
import org.chromium.chrome.browser.compositor.layouts.Layout;
import org.chromium.chrome.browser.layouts.scene_layer.SceneLayer;
import org.chromium.chrome.browser.tab_ui.TabContentManager;
import org.chromium.chrome.browser.tabmodel.TabModelSelector;
import org.chromium.ui.resources.ResourceManager;

public class ClassicStackSceneLayer extends SceneLayer {
    public ClassicStackSceneLayer() {}

    public void setTabModelSelector(TabModelSelector modelSelector) {}

    public void pushLayers(
            Context context,
            RectF viewport,
            RectF contentViewport,
            Layout layout,
            TabContentManager tabContentManager,
            ResourceManager resourceManager,
            BrowserControlsStateProvider browserControls,
            int backgroundResourceId,
            int backgroundResourceOffset,
            int backgroundResourceWidth) {
        // Pure compositor-managed rendering pass
    }
}
