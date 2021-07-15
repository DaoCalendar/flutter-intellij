/*
 * Copyright 2019 The Chromium Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 */
package io.flutter.devtools;

import org.junit.Test;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

public class DevToolsUtilsTest {
  @Test
  public void testFindWidgetId() {
    String url = "http://127.0.0.1:9102/#/inspector?uri=http%3A%2F%2F127.0.0.1%3A51805%2FP-f92tUS3r8%3D%2F&inspectorRef=inspector-238";
    assertEquals(
            "inspector-238",
            DevToolsUtils.findWidgetId(url)
    );

    String noIdUrl = "http://127.0.0.1:9102/#/inspector?uri=http%3A%2F%2F127.0.0.1%3A51805%2FP-f92tUS3r8%3D%2F";
    assertNull(DevToolsUtils.findWidgetId(noIdUrl));
  }
}
