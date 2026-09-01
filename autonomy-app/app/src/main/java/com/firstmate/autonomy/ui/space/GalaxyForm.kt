package com.firstmate.autonomy.ui.space

import com.firstmate.autonomy.domain.model.Goal
import kotlin.math.PI
import kotlin.math.abs

/**
 * A small deterministic random source.
 *
 * Deterministic matters here: a goal's galaxy is drawn from its id, so the
 * same goal looks the same on every launch and on every device. Without that,
 * the space view would rearrange itself each time the app started and stop
 * being a place you can learn.
 */
class Rng(seed: Long) {
    private var state: Int = (seed xor 0x9E3779B9L).toInt()

    fun next(): Float {
        state += -0x61c88647
        var z = state
        z = (z xor (z ushr 16)) * -0x7ee3623b
        z = (z xor (z ushr 13)) * -0x3d4d51cb
        z = z xor (z ushr 16)
        return abs(z.toFloat() / Int.MAX_VALUE).coerceIn(0f, 0.999999f)
    }

    fun between(lo: Float, hi: Float): Float = lo + next() * (hi - lo)

    fun int(bound: Int): Int = (next() * bound).toInt().coerceIn(0, bound - 1)
}

/** The families a galaxy can belong to. */
enum class GalaxyType { SPIRAL, BARRED, RING, LENTICULAR, IRREGULAR, ELLIPTICAL }

/**
 * Everything that decides what one galaxy looks like.
 *
 * These are generated from the goal's id rather than stored, so no two goals
 * share a form and nothing has to be migrated when the renderer changes.
 */
data class GalaxyForm(
    val type: GalaxyType,
    val arms: Int,
    val pitch: Float,
    val bar: Float,
    val inclination: Float,
    val positionAngle: Float,
    val particles: Int,
    val concentration: Float,
    val flocculence: Float,
    val dust: Float,
    val bulge: Float,
    val hiiRegions: Int,
    val ringRadius: Float,
    val seed: Long,
) {
    /** Edge-on discs barely appear to turn, so spin falls away with inclination. */
    val spin: Float get() = (0.010f + (seed % 7) * 0.0012f) * (1f - inclination * 0.85f) *
        if (seed % 2L == 0L) 1f else -1f

    companion object {
        fun forGoal(goal: Goal): GalaxyForm = forSeed(goal.id * 7919L + 13L)

        fun forSeed(seed: Long): GalaxyForm {
            val rng = Rng(seed)
            val type = GalaxyType.entries[rng.int(GalaxyType.entries.size)]
            val arms = when (type) {
                GalaxyType.SPIRAL -> 2 + rng.int(3)
                GalaxyType.BARRED -> 2
                else -> 0
            }
            return GalaxyForm(
                type = type,
                arms = arms,
                pitch = rng.between(0.20f, 0.42f),
                bar = if (type == GalaxyType.BARRED) rng.between(0.18f, 0.32f) else 0f,
                inclination = when (type) {
                    GalaxyType.LENTICULAR -> rng.between(0.55f, 0.72f)
                    GalaxyType.ELLIPTICAL -> rng.between(0.30f, 0.50f)
                    else -> rng.between(0.08f, 0.60f)
                },
                positionAngle = rng.between(-PI.toFloat(), PI.toFloat()),
                particles = when (type) {
                    GalaxyType.ELLIPTICAL -> 3200
                    GalaxyType.IRREGULAR -> 4200
                    else -> 5200
                },
                concentration = if (type == GalaxyType.ELLIPTICAL) 0.85f else rng.between(0.48f, 0.6f),
                flocculence = rng.between(0.5f, 1.3f),
                dust = when (type) {
                    GalaxyType.ELLIPTICAL -> 0f
                    GalaxyType.LENTICULAR -> 1.1f
                    else -> rng.between(0.7f, 1.4f)
                },
                bulge = rng.between(0.10f, 0.22f),
                hiiRegions = when (type) {
                    GalaxyType.ELLIPTICAL, GalaxyType.LENTICULAR -> 0
                    else -> 55 + rng.int(45)
                },
                ringRadius = rng.between(0.55f, 0.68f),
                seed = seed,
            )
        }
    }
}
