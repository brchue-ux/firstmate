package com.firstmate.autonomy.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import com.firstmate.autonomy.ui.preview.ThemePreviews
import com.firstmate.autonomy.ui.theme.AutonomyTheme

/**
 * Labelled progress bar used for project completion and habit consistency.
 *
 * The bar and its caption are collapsed into a single accessibility node so a
 * screen reader announces "Milestones, 3 of 5, 60 percent" rather than
 * three disconnected fragments.
 */
@Composable
fun LabeledProgress(
    label: String,
    progress: Float,
    modifier: Modifier = Modifier,
    trailingText: String? = null,
    accessibilityText: String = "$label ${(progress * 100).toInt()} percent",
) {
    val animated by animateFloatAsState(
        targetValue = progress.coerceIn(0f, 1f),
        label = "progress",
    )
    Column(
        modifier = modifier.clearAndSetSemantics {
            contentDescription = accessibilityText
        },
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = label,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (trailingText != null) {
                Text(
                    text = trailingText,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Spacer(Modifier.height(6.dp))
        LinearProgressIndicator(
            progress = { animated },
            modifier = Modifier
                .fillMaxWidth()
                .height(8.dp)
                .clip(RoundedCornerShape(4.dp)),
            trackColor = MaterialTheme.colorScheme.surfaceVariant,
            gapSize = 0.dp,
            drawStopIndicator = {},
        )
    }
}

@ThemePreviews
@Composable
private fun LabeledProgressPreview() {
    AutonomyTheme {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            LabeledProgress(label = "Milestones", progress = 0.6f, trailingText = "3 of 5")
            LabeledProgress(label = "This week", progress = 1f, trailingText = "100%")
            LabeledProgress(label = "Not started", progress = 0f, trailingText = "0 of 4")
        }
    }
}
