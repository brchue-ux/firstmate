package com.firstmate.autonomy.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.hapticfeedback.HapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import com.firstmate.autonomy.ui.preview.ThemePreviews
import com.firstmate.autonomy.ui.theme.AutonomyTheme
import com.firstmate.autonomy.ui.theme.ConfettiColors
import kotlin.math.cos
import kotlin.math.sin
import kotlin.random.Random

/**
 * One confetti particle. Positions are in fractions of the burst's own size, so
 * the simulation is resolution-independent and never needs re-seeding on a
 * rotation or a size change.
 */
private data class Particle(
    val angleRadians: Float,
    val speed: Float,
    val color: Color,
    val widthDp: Float,
    val heightDp: Float,
    val spin: Float,
    val spinOffset: Float,
    val drift: Float,
)

private const val PARTICLE_COUNT = 44
private const val GRAVITY = 1.9f

/**
 * A lightweight celebratory burst drawn on a single [Canvas].
 *
 * Deliberately not a particle *engine*: one `animateFloatAsState` drives a
 * normalised 0..1 progress, and each particle's position is a pure function of
 * that progress and its own seed. So there is no per-frame allocation, no
 * physics state to keep in sync, and stopping it is just letting the animation
 * finish.
 *
 * Draws nothing and costs nothing while [visible] is false.
 *
 * Accessibility: purely decorative, so it is hidden from the semantics tree and
 * never announced. It also respects the system's reduced-animation setting by
 * way of [enabled], which the caller sources from user preference.
 */
@Composable
fun ConfettiEffect(
    visible: Boolean,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    durationMillis: Int = 1400,
    onFinished: () -> Unit = {},
) {
    if (!enabled) {
        // Still consume the trigger, or the caller waits forever for onFinished.
        val currentOnFinished by rememberUpdatedState(onFinished)
        LaunchedEffect(visible) { if (visible) currentOnFinished() }
        return
    }

    var running by remember { mutableStateOf(false) }
    val currentOnFinished by rememberUpdatedState(onFinished)

    // Re-seeded per burst so two celebrations never look identical.
    val particles = remember(visible) {
        if (!visible) emptyList() else List(PARTICLE_COUNT) {
            val spread = Random.nextFloat()
            Particle(
                // Biased upward: a burst that mostly falls back down reads better.
                angleRadians = (-160f + spread * 140f) * (Math.PI.toFloat() / 180f),
                speed = 0.55f + Random.nextFloat() * 0.75f,
                color = ConfettiColors[Random.nextInt(ConfettiColors.size)],
                widthDp = 5f + Random.nextFloat() * 5f,
                heightDp = 9f + Random.nextFloat() * 7f,
                spin = 2f + Random.nextFloat() * 7f,
                spinOffset = Random.nextFloat() * 360f,
                drift = (Random.nextFloat() - 0.5f) * 0.35f,
            )
        }
    }

    LaunchedEffect(visible) { running = visible }

    val progress by animateFloatAsState(
        targetValue = if (running) 1f else 0f,
        animationSpec = tween(durationMillis = durationMillis, easing = LinearEasing),
        label = "confetti",
        finishedListener = { value ->
            if (value == 1f) {
                running = false
                currentOnFinished()
            }
        },
    )

    if (!visible && progress == 0f) return

    Box(
        modifier = modifier
            .fillMaxSize()
            // Decorative only: no semantics node, so it is never announced.
            .clearAndSetSemantics { },
    ) {
        Canvas(Modifier.fillMaxSize()) {
            if (progress <= 0f) return@Canvas
            val origin = Offset(size.width / 2f, size.height * 0.42f)
            particles.forEach { particle -> drawParticle(particle, progress, origin) }
        }
    }
}

/**
 * Position is ballistic: constant horizontal velocity, vertical velocity plus
 * gravity integrated over normalised time. Opacity fades over the last third so
 * particles dissolve rather than vanishing mid-flight.
 */
private fun DrawScope.drawParticle(particle: Particle, progress: Float, origin: Offset) {
    val reach = size.minDimension
    val vx = cos(particle.angleRadians) * particle.speed
    val vy = sin(particle.angleRadians) * particle.speed

    val x = origin.x + (vx + particle.drift * progress) * progress * reach
    val y = origin.y + (vy * progress + GRAVITY * progress * progress / 2f) * reach

    val alpha = when {
        progress < 0.1f -> progress / 0.1f
        progress > 0.65f -> ((1f - progress) / 0.35f).coerceIn(0f, 1f)
        else -> 1f
    }
    if (alpha <= 0f) return

    val w = particle.widthDp.dp.toPx()
    val h = particle.heightDp.dp.toPx()

    rotate(degrees = particle.spinOffset + particle.spin * progress * 360f, pivot = Offset(x, y)) {
        drawRect(
            color = particle.color.copy(alpha = alpha),
            topLeft = Offset(x - w / 2f, y - h / 2f),
            size = Size(w, h),
        )
    }
}

/**
 * Fires haptic feedback for a completion. Kept beside the confetti so the two
 * halves of "you finished something" stay together, and so a caller cannot ship
 * the visual without the physical cue.
 */
@Composable
fun rememberCelebration(enabled: Boolean = true): Celebration {
    val haptics = LocalHapticFeedback.current
    return remember(haptics, enabled) { Celebration(haptics, enabled) }
}

class Celebration(
    private val haptics: HapticFeedback,
    private val enabled: Boolean,
) {
    fun tap() {
        if (enabled) haptics.performHapticFeedback(HapticFeedbackType.LongPress)
    }
}

@ThemePreviews
@Composable
private fun ConfettiPreview() {
    AutonomyTheme {
        Box(Modifier.fillMaxSize()) {
            ConfettiEffect(visible = true)
        }
    }
}
