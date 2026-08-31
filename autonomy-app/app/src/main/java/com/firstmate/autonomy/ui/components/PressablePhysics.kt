package com.firstmate.autonomy.ui.components

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.interaction.InteractionSource
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonColors
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.unit.dp
import com.firstmate.autonomy.ui.preview.ThemePreviews
import com.firstmate.autonomy.ui.theme.AutonomyShape
import com.firstmate.autonomy.ui.theme.AutonomyTheme

/**
 * Springs a composable down while it is held and lets it overshoot back.
 *
 * Driven by the real [InteractionSource] rather than a manual pointer handler,
 * so it stays in step with ripple, focus and accessibility activation, and a
 * gesture cancelled by a scroll releases the scale correctly.
 */
@Composable
fun Modifier.pressPhysics(
    interactionSource: InteractionSource,
    pressedScale: Float = 0.94f,
): Modifier {
    val pressed by interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed) pressedScale else 1f,
        animationSpec = spring(
            dampingRatio = Spring.DampingRatioMediumBouncy,
            stiffness = Spring.StiffnessMediumLow,
        ),
        label = "pressScale",
    )
    return this.scale(scale)
}

/**
 * The app's primary call to action: deep indigo fill, 20dp corners, and the
 * press spring above.
 *
 * It uses the *container* colour pair rather than `primary`, because deep
 * indigo cannot legibly carry text on this background - see the note in
 * Color.kt.
 */
@Composable
fun PrimaryActionButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    colors: ButtonColors = ButtonDefaults.buttonColors(
        containerColor = MaterialTheme.colorScheme.primaryContainer,
        contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
    ),
    leadingIcon: @Composable (() -> Unit)? = null,
) {
    val interactionSource = remember { MutableInteractionSource() }
    Button(
        onClick = onClick,
        modifier = modifier.pressPhysics(interactionSource),
        enabled = enabled,
        shape = AutonomyShape.card,
        colors = colors,
        interactionSource = interactionSource,
        contentPadding = ButtonDefaults.ContentPadding,
    ) {
        leadingIcon?.invoke()
        Text(text, style = MaterialTheme.typography.labelLarge)
    }
}

@ThemePreviews
@Composable
private fun PrimaryActionButtonPreview() {
    AutonomyTheme {
        Column(
            Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            PrimaryActionButton(text = "Create project", onClick = {})
            PrimaryActionButton(text = "Disabled", onClick = {}, enabled = false)
        }
    }
}
