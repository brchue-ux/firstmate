package com.firstmate.autonomy.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.firstmate.autonomy.domain.model.DecisionCategory
import com.firstmate.autonomy.domain.model.DomainStatus
import com.firstmate.autonomy.ui.preview.ThemePreviews
import com.firstmate.autonomy.ui.theme.AutonomyShape
import com.firstmate.autonomy.ui.theme.AutonomyTheme

/** Pill showing a project's stage, with a dot in the stage's accent. */
@Composable
fun DomainStatusChip(
    status: DomainStatus,
    modifier: Modifier = Modifier,
) {
    val accent = AutonomyTheme.accents.forStatus(status)
    LabelChip(
        text = status.label,
        modifier = modifier,
        leading = {
            Spacer(
                Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(accent),
            )
        },
    )
}

/** Category pill for a logged decision. */
@Composable
fun DecisionCategoryChip(
    category: DecisionCategory,
    modifier: Modifier = Modifier,
) {
    LabelChip(text = category.label, modifier = modifier)
}

/** Neutral, non-interactive pill. Chips here are labels, not controls. */
@Composable
fun LabelChip(
    text: String,
    modifier: Modifier = Modifier,
    containerColor: Color = MaterialTheme.colorScheme.surfaceContainerHighest,
    contentColor: Color = MaterialTheme.colorScheme.onSurfaceVariant,
    leading: @Composable (() -> Unit)? = null,
) {
    Surface(
        modifier = modifier,
        shape = AutonomyShape.chip,
        color = containerColor,
        contentColor = contentColor,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            leading?.invoke()
            Text(text = text, style = MaterialTheme.typography.labelMedium)
        }
    }
}

@ThemePreviews
@Composable
private fun StatusChipPreview() {
    AutonomyTheme {
        Row(
            modifier = Modifier.padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            DomainStatus.entries.forEach { DomainStatusChip(it) }
            DecisionCategoryChip(DecisionCategory.FAMILY_DYNAMICS)
        }
    }
}
