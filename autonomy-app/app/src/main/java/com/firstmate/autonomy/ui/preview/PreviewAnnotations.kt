package com.firstmate.autonomy.ui.preview

import android.content.res.Configuration
import androidx.compose.ui.tooling.preview.Preview

/**
 * Multipreview annotation: every composable tagged with it renders twice in the
 * Compose preview pane, once per theme. Saves repeating two @Preview blocks
 * on every component.
 */
@Preview(name = "Light", showBackground = true)
@Preview(
    name = "Dark",
    showBackground = true,
    uiMode = Configuration.UI_MODE_NIGHT_YES,
)
annotation class ThemePreviews

/** Full-screen variant with a device-sized frame. */
@Preview(name = "Light", showBackground = true, widthDp = 400, heightDp = 860)
@Preview(
    name = "Dark",
    showBackground = true,
    widthDp = 400,
    heightDp = 860,
    uiMode = Configuration.UI_MODE_NIGHT_YES,
)
annotation class ScreenPreviews
