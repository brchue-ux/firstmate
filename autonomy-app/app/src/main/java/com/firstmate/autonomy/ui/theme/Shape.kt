package com.firstmate.autonomy.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Shapes
import androidx.compose.ui.unit.dp

/**
 * Corner scale. `large` is 20dp because that is the elevated-card radius the
 * design calls for; Material 3 routes Card through `medium` by default, so
 * cards in this app set their shape explicitly to [AutonomyShapes.card].
 */
val AutonomyShapes = Shapes(
    extraSmall = RoundedCornerShape(6.dp),
    small = RoundedCornerShape(10.dp),
    medium = RoundedCornerShape(16.dp),
    large = RoundedCornerShape(20.dp),
    extraLarge = RoundedCornerShape(28.dp),
)

/** Named shapes for the places where the scale alone is ambiguous. */
object AutonomyShape {
    val card = RoundedCornerShape(20.dp)
    val sheet = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)
    val chip = RoundedCornerShape(10.dp)
    val ring = RoundedCornerShape(50)
}
