// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.camera.view.PreviewView;

/**
 * ProxyApi implementation for {@link PreviewViewUtils}. This class may handle instantiating native
 * object instances that are attached to a Dart instance or handle method calls on the associated
 * native class or an instance of that class.
 */
public class PreviewViewUtilsProxyApi extends PigeonApiPreviewViewUtils {
  PreviewViewUtilsProxyApi(@NonNull ProxyApiRegistrar pigeonRegistrar) {
    super(pigeonRegistrar);
  }

  @Nullable
  @Override
  public byte[] capturePreviewFrame(
      @NonNull PreviewView previewView, long maxShortSide, long jpegQuality) {
    return PreviewViewUtils.capturePreviewFrame(previewView, (int) maxShortSide, (int) jpegQuality);
  }
}
