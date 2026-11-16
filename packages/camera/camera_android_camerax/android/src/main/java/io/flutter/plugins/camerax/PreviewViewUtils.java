// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import android.graphics.Bitmap;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.camera.view.PreviewView;
import java.io.ByteArrayOutputStream;

/** Utility class for working with {@link PreviewView}s. */
public class PreviewViewUtils {
  /**
   * Returns the content of {@code previewView} as a JPEG whose short side is at most {@code
   * maxShortSide} pixels, or null if the view shows no frame. Must be called on the main thread.
   */
  @Nullable
  public static byte[] capturePreviewFrame(
      @NonNull PreviewView previewView, int maxShortSide, int jpegQuality) {
    final Bitmap bitmap = previewView.getBitmap();
    if (bitmap == null) {
      return null;
    }
    final int shortSide = Math.min(bitmap.getWidth(), bitmap.getHeight());
    Bitmap scaled = bitmap;
    if (shortSide > maxShortSide) {
      final double scale = (double) maxShortSide / shortSide;
      scaled =
          Bitmap.createScaledBitmap(
              bitmap,
              (int) Math.round(bitmap.getWidth() * scale),
              (int) Math.round(bitmap.getHeight() * scale),
              true);
      bitmap.recycle();
    }
    final ByteArrayOutputStream output = new ByteArrayOutputStream();
    scaled.compress(Bitmap.CompressFormat.JPEG, jpegQuality, output);
    scaled.recycle();
    return output.toByteArray();
  }
}
