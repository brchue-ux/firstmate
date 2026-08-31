package com.firstmate.autonomy.ui.navigation

import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.navigation.NavBackStackEntry

/**
 * Screen transitions.
 *
 * Two distinct motions, because they mean different things:
 *
 * - Pushing into a detail or an editor slides horizontally. The new screen
 *   arrives from the side it will leave towards, so the back stack has a
 *   consistent spatial direction.
 * - Switching bottom-bar tabs cross-fades. Tabs are siblings, not a hierarchy;
 *   sliding between them would imply an order that does not exist.
 *
 * The outgoing screen only travels a third as far as the incoming one, which is
 * the standard parallax that keeps the two layers visually distinct rather than
 * appearing glued together.
 */
private const val PUSH_MILLIS = 320
private const val POP_MILLIS = 280
private const val FADE_MILLIS = 220
private const val PARALLAX = 3

/** Material's standard decelerate curve: quick to start, settles gently. */
private val Emphasised = CubicBezierEasing(0.05f, 0.7f, 0.1f, 1f)

fun AnimatedContentTransitionScope<NavBackStackEntry>.pushEnter(): EnterTransition =
    slideInHorizontally(
        animationSpec = tween(PUSH_MILLIS, easing = Emphasised),
        initialOffsetX = { fullWidth -> fullWidth },
    ) + fadeIn(animationSpec = tween(FADE_MILLIS))

fun AnimatedContentTransitionScope<NavBackStackEntry>.pushExit(): ExitTransition =
    slideOutHorizontally(
        animationSpec = tween(PUSH_MILLIS, easing = Emphasised),
        targetOffsetX = { fullWidth -> -fullWidth / PARALLAX },
    ) + fadeOut(animationSpec = tween(FADE_MILLIS))

fun AnimatedContentTransitionScope<NavBackStackEntry>.popEnter(): EnterTransition =
    slideInHorizontally(
        animationSpec = tween(POP_MILLIS, easing = Emphasised),
        initialOffsetX = { fullWidth -> -fullWidth / PARALLAX },
    ) + fadeIn(animationSpec = tween(FADE_MILLIS))

fun AnimatedContentTransitionScope<NavBackStackEntry>.popExit(): ExitTransition =
    slideOutHorizontally(
        animationSpec = tween(POP_MILLIS, easing = Emphasised),
        targetOffsetX = { fullWidth -> fullWidth },
    ) + fadeOut(animationSpec = tween(FADE_MILLIS))

/** Siblings cross-fade. */
fun tabEnter(): EnterTransition = fadeIn(animationSpec = tween(FADE_MILLIS))

fun tabExit(): ExitTransition = fadeOut(animationSpec = tween(FADE_MILLIS))
