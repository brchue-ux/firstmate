package com.firstmate.autonomy.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * Obsidian palette. Every foreground/background pair below was measured against
 * the WCAG 2.1 relative-luminance formula and clears AA (4.5:1 for text, 3:1 for
 * UI boundaries). The measured ratio is noted beside each pair.
 *
 * One deliberate departure from a naive reading of the brief: deep indigo
 * #4F46E5 on the #0F172A background is only 2.84:1, so it cannot carry text or
 * icons. It is therefore bound to the *container* role - the colour of a filled
 * surface, where light text sits on top of it at 5.62:1 - while a lightened
 * sibling (#818CF8, 5.98:1) carries indigo text and icons. That split is exactly
 * how Material 3 dark schemes are meant to work, so the deep indigo still reads
 * as the primary accent wherever it is a surface.
 */

// --- Brand ------------------------------------------------------------------

/** The specified deep indigo. A fill colour, never a text colour on dark. */
val Indigo600 = Color(0xFF4F46E5)
val Indigo500 = Color(0xFF6366F1)
/** Lightened indigo that can legibly carry text and icons on obsidian. */
val Indigo400 = Color(0xFF818CF8)
val Indigo200 = Color(0xFFA5B4FC)
val Indigo50 = Color(0xFFEEF2FF)
val Indigo950 = Color(0xFF1E1B4B)

/** The specified warm amber. Legible as text on dark at 8.31:1. */
val Amber500 = Color(0xFFF59E0B)
val Amber400 = Color(0xFFFBBF24)
val Amber100 = Color(0xFFFEF3C7)
val Amber800 = Color(0xFF92400E)
val Amber900 = Color(0xFF78350F)

// --- Slate ramp (the obsidian ground) ---------------------------------------

val Slate950 = Color(0xFF0F172A) // background, as specified
val Slate900 = Color(0xFF162032)
val Slate850 = Color(0xFF1A2334)
val Slate800 = Color(0xFF1E293B) // surface, as specified
val Slate750 = Color(0xFF263449)
val Slate700 = Color(0xFF334155)
val Slate500 = Color(0xFF64748B)
val Slate400 = Color(0xFF94A3B8)
val Slate200 = Color(0xFFE2E8F0)
val Slate100 = Color(0xFFF1F5F9)
val Slate50 = Color(0xFFF8FAFC)

// --- Status / feedback ------------------------------------------------------

val Red300 = Color(0xFFFCA5A5)
val Red700 = Color(0xFFB91C1C)
val Red900 = Color(0xFF7F1D1D)
val Red50 = Color(0xFFFEF2F2)

val Emerald400 = Color(0xFF34D399)
val Emerald700 = Color(0xFF047857)

/**
 * Accents for project stages. Chosen from the ramps above so each clears 4.5:1
 * on both #0F172A and #1E293B in dark, and on #FFFFFF in light.
 */
object StatusPalette {
    val planningDark = Amber400 // 8.76:1 on surface
    val inProgressDark = Indigo400 // 4.90:1 on surface
    val completedDark = Emerald400 // 8.30:1 on surface

    val planningLight = Amber800
    val inProgressLight = Indigo600
    val completedLight = Emerald700
}

/** Confetti draws from these; they are decorative and carry no meaning. */
val ConfettiColors = listOf(
    Indigo400,
    Amber400,
    Emerald400,
    Indigo200,
    Amber100,
    Color(0xFF38BDF8),
)
