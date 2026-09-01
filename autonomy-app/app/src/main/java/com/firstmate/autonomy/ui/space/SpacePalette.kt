package com.firstmate.autonomy.ui.space

import androidx.compose.ui.graphics.Color
import com.firstmate.autonomy.domain.model.SurfaceKind

/**
 * Naturalistic colour, not neon.
 *
 * Real disc galaxies are a warm core of old stars fading to cooler arms, with
 * pink hydrogen knots where new stars are forming. Following that gives every
 * galaxy a family resemblance without any two being the same, and keeps the
 * whole view legible on a black ground - saturated primaries at these sizes
 * blow out to white the moment two of them overlap.
 */
object SpacePalette {

    /** Core, arm and hydrogen colour for one galaxy, chosen from its id. */
    data class GalaxyColors(val core: Int, val arm: Int, val hii: Int)

    private val cores = intArrayOf(
        0xFFFFCE78.toInt(), 0xFFFFDDA0.toInt(), 0xFFFFB761.toInt(),
        0xFFDCC79A.toInt(), 0xFFFFBE64.toInt(), 0xFFFFDFAE.toInt(),
        0xFFFFDD9C.toInt(), 0xFFFFD4BC.toInt(),
    )
    private val arms = intArrayOf(
        0xFF8FB6FF.toInt(), 0xFF6FA5F0.toInt(), 0xFFD8914F.toInt(),
        0xFF6E695E.toInt(), 0xFFBE8646.toInt(), 0xFF63A6C6.toInt(),
        0xFF79C29B.toInt(), 0xFF9A7A8E.toInt(),
    )
    private val hiis = intArrayOf(
        0xFFFF6E8E.toInt(), 0xFFFF6E86.toInt(), 0xFFFF6E45.toInt(),
        0xFF6E695E.toInt(), 0xFFFF8450.toInt(), 0xFFE96E88.toInt(),
        0xFFFF6E63.toInt(), 0xFF9A7A8E.toInt(),
    )

    fun galaxyColors(seed: Long): GalaxyColors {
        val i = ((seed / 7919L).toInt().let { if (it < 0) -it else it }) % cores.size
        return GalaxyColors(cores[i], arms[i], hiis[i])
    }

    /** Base, shadow and highlight for a planet's surface, plus its air colour. */
    data class SurfaceColors(
        val base: Int,
        val dark: Int,
        val light: Int,
        val air: Int?,
        val style: Style,
    ) {
        enum class Style { ROCK, GAS, ICE, OCEAN }
    }

    fun surfaceColors(kind: SurfaceKind): SurfaceColors = when (kind) {
        SurfaceKind.ROCK -> SurfaceColors(
            0xFF8A7A6B.toInt(), 0xFF5C5046.toInt(), 0xFFC4B5A2.toInt(),
            0xFFC8B79E.toInt(), SurfaceColors.Style.ROCK,
        )
        SurfaceKind.DESERT -> SurfaceColors(
            0xFFB08856.toInt(), 0xFF7A5A34.toInt(), 0xFFE7C48C.toInt(),
            0xFFE8C08A.toInt(), SurfaceColors.Style.ROCK,
        )
        SurfaceKind.BASALT -> SurfaceColors(
            0xFF5E5C61.toInt(), 0xFF3A383E.toInt(), 0xFF93919A.toInt(),
            null, SurfaceColors.Style.ROCK,
        )
        SurfaceKind.EMBER -> SurfaceColors(
            0xFF8C5340.toInt(), 0xFF4E2A20.toInt(), 0xFFD89268.toInt(),
            0xFFD08A62.toInt(), SurfaceColors.Style.ROCK,
        )
        SurfaceKind.ICE -> SurfaceColors(
            0xFFB9C8CE.toInt(), 0xFF7C8F9A.toInt(), 0xFFEAF2F5.toInt(),
            0xFFCFE2EA.toInt(), SurfaceColors.Style.ICE,
        )
        SurfaceKind.GAS -> SurfaceColors(
            0xFFC9A87C.toInt(), 0xFF8A6A46.toInt(), 0xFFEFD9B4.toInt(),
            0xFFE9CFA6.toInt(), SurfaceColors.Style.GAS,
        )
        SurfaceKind.CLOUD -> SurfaceColors(
            0xFF9FAAB6.toInt(), 0xFF69737F.toInt(), 0xFFDFE6EC.toInt(),
            0xFFC6D3DE.toInt(), SurfaceColors.Style.GAS,
        )
        SurfaceKind.OCEAN -> SurfaceColors(
            0xFF4E7186.toInt(), 0xFF2E4959.toInt(), 0xFF9FC2CE.toInt(),
            0xFF9EC6D6.toInt(), SurfaceColors.Style.OCEAN,
        )
    }

    val moonSurface = SurfaceColors(
        0xFF9A958D.toInt(), 0xFF66625C.toInt(), 0xFFD6D1C7.toInt(),
        null, SurfaceColors.Style.ROCK,
    )

    /** Chrome for the space view, kept off the Material scheme deliberately. */
    val void = Color(0xFF05060C)
    val label = Color(0xFFB9B2DE)
    val labelDim = Color(0xFF7E86A8)
    val warmLabel = Color(0xFFE0A46A)
    val coldLabel = Color(0xFF5C6B86)
}
