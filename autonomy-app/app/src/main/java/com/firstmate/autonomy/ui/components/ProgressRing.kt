package com.firstmate.autonomy.ui.components

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.firstmate.autonomy.ui.preview.ThemePreviews
import com.firstmate.autonomy.ui.theme.AutonomyTheme
import kotlin.math.min

/**
 * A closed completion ring in the spirit of the Fitness rings: a full-circle
 * track with a rounded-cap sweep over it, animated with a spring so a ticked
 * milestone visibly *travels* rather than jumping.
 *
 * The whole ring plus its centre label is one accessibility node reading
 * "<label>, 60 percent" - a screen reader gets the number, not the geometry.
 */
@Composable
fun ProgressRing(
    progress: Float,
    modifier: Modifier = Modifier,
    size: Dp = 96.dp,
    strokeWidth: Dp = 10.dp,
    color: Color = MaterialTheme.colorScheme.primary,
    trackColor: Color = MaterialTheme.colorScheme.surfaceContainerHighest,
    label: String? = null,
    contentDescriptionText: String? = null,
    centerContent: @Composable (() -> Unit)? = null,
) {
    val target = progress.coerceIn(0f, 1f)
    val animated by animateFloatAsState(
        targetValue = target,
        animationSpec = spring(
            dampingRatio = Spring.DampingRatioLowBouncy,
            stiffness = Spring.StiffnessLow,
        ),
        label = "ring",
    )
    val percent = (target * 100).toInt()
    val description = contentDescriptionText
        ?: listOfNotNull(label, "$percent percent complete").joinToString(", ")

    Box(
        modifier = modifier
            .size(size)
            .clearAndSetSemantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(size)) {
            val stroke = strokeWidth.toPx()
            val inset = stroke / 2f
            val diameter = min(this.size.width, this.size.height) - stroke
            val topLeft = Offset(inset, inset)
            val arcSize = Size(diameter, diameter)

            drawArc(
                color = trackColor,
                startAngle = 0f,
                sweepAngle = 360f,
                useCenter = false,
                topLeft = topLeft,
                size = arcSize,
                style = Stroke(width = stroke, cap = StrokeCap.Round),
            )

            if (animated > 0f) {
                drawArc(
                    // A sweep gradient makes a full ring read as travelled
                    // distance rather than a flat disc outline.
                    brush = Brush.sweepGradient(
                        0f to color.copy(alpha = 0.55f),
                        animated.coerceAtLeast(0.01f) to color,
                        1f to color.copy(alpha = 0.55f),
                    ),
                    startAngle = -90f,
                    sweepAngle = 360f * animated,
                    useCenter = false,
                    topLeft = topLeft,
                    size = arcSize,
                    style = Stroke(width = stroke, cap = StrokeCap.Round),
                )
            }
        }

        if (centerContent != null) {
            centerContent()
        } else {
            Text(
                text = "$percent%",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
    }
}

@ThemePreviews
@Composable
private fun ProgressRingPreview() {
    AutonomyTheme {
        Row(
            Modifier.padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ProgressRing(progress = 0f, label = "Not started")
            ProgressRing(progress = 0.6f, label = "Ticked")
            ProgressRing(
                progress = 1f,
                label = "Done",
                color = MaterialTheme.colorScheme.tertiary,
            )
        }
    }
}
