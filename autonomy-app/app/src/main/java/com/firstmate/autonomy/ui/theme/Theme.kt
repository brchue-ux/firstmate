package com.firstmate.autonomy.ui.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import com.firstmate.autonomy.domain.model.GoalStatus

/**
 * The obsidian scheme.
 *
 * The app commits to it rather than following the system light/dark setting.
 * The brief specifies obsidian as the product's identity, so a phone in light
 * mode must not silently get a different-looking app - which is exactly what
 * happened: the design was invisible to anyone whose device was set to light.
 *
 * The light scheme is kept and held to the same AA bar. It is what the
 * side-by-side previews render, and it is the ready-made other half if a
 * follow-the-system setting is ever added.
 *
 * Dynamic (wallpaper) colour is deliberately NOT used: the brief specifies an
 * exact brand palette, and dynamic colour would silently replace it with hues
 * whose contrast has never been measured.
 */
private val ObsidianDark = darkColorScheme(
    // Indigo splits across two roles - see the note in Color.kt.
    primary = Indigo400,
    onPrimary = Slate950,
    primaryContainer = Indigo600,
    onPrimaryContainer = Indigo50,
    inversePrimary = Indigo600,

    secondary = Amber400,
    onSecondary = Slate950,
    secondaryContainer = Amber900,
    onSecondaryContainer = Amber100,

    tertiary = Emerald400,
    onTertiary = Slate950,
    tertiaryContainer = Emerald700,
    onTertiaryContainer = Slate50,

    error = Red300,
    onError = Slate950,
    errorContainer = Red900,
    onErrorContainer = Red50,

    background = Slate950,
    onBackground = Slate200,
    surface = Slate950,
    onSurface = Slate200,
    surfaceVariant = Slate700,
    onSurfaceVariant = Slate400,

    // The elevation ramp above the obsidian ground.
    surfaceContainerLowest = Slate950,
    surfaceContainerLow = Slate900,
    surfaceContainer = Slate850,
    surfaceContainerHigh = Slate800,
    surfaceContainerHighest = Slate750,

    outline = Slate500,
    outlineVariant = Slate700,
    scrim = Color(0xFF000000),
)

private val ObsidianLight = lightColorScheme(
    primary = Color(0xFF4338CA),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Indigo50,
    onPrimaryContainer = Indigo950,
    inversePrimary = Indigo400,

    secondary = Amber800,
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Amber100,
    onSecondaryContainer = Amber900,

    tertiary = Emerald700,
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFD1FAE5),
    onTertiaryContainer = Color(0xFF064E3B),

    error = Red700,
    onError = Color(0xFFFFFFFF),
    errorContainer = Red50,
    onErrorContainer = Red900,

    background = Slate50,
    onBackground = Slate950,
    surface = Color(0xFFFFFFFF),
    onSurface = Slate950,
    surfaceVariant = Slate100,
    onSurfaceVariant = Color(0xFF475569),

    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Slate50,
    surfaceContainer = Slate100,
    surfaceContainerHigh = Color(0xFFE8EDF3),
    surfaceContainerHighest = Slate200,

    outline = Slate500,
    outlineVariant = Color(0xFFCBD5E1),
    scrim = Color(0xFF000000),
)

/**
 * Stage accents are not part of [ColorScheme], so they ride alongside it in a
 * CompositionLocal rather than being re-derived at each call site.
 */
data class AutonomyAccentColors(
    val planning: Color,
    val inProgress: Color,
    val completed: Color,
) {
    fun forStatus(status: GoalStatus): Color = when (status) {
        GoalStatus.PAUSED -> planning
        GoalStatus.ACTIVE -> inProgress
        GoalStatus.DONE -> completed
    }
}

private val DarkAccents = AutonomyAccentColors(
    planning = StatusPalette.planningDark,
    inProgress = StatusPalette.inProgressDark,
    completed = StatusPalette.completedDark,
)

private val LightAccents = AutonomyAccentColors(
    planning = StatusPalette.planningLight,
    inProgress = StatusPalette.inProgressLight,
    completed = StatusPalette.completedLight,
)

val LocalAutonomyAccents = staticCompositionLocalOf { DarkAccents }

@Composable
fun AutonomyTheme(
    darkTheme: Boolean = true,
    content: @Composable () -> Unit,
) {
    val colorScheme = if (darkTheme) ObsidianDark else ObsidianLight
    val accents = if (darkTheme) DarkAccents else LightAccents

    CompositionLocalProvider(LocalAutonomyAccents provides accents) {
        MaterialTheme(
            colorScheme = colorScheme,
            typography = AutonomyTypography,
            shapes = AutonomyShapes,
            content = content,
        )
    }
}

/** Shorthand for the stage accents at a call site. */
object AutonomyTheme {
    val accents: AutonomyAccentColors
        @Composable @ReadOnlyComposable get() = LocalAutonomyAccents.current
}
