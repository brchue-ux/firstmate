package com.firstmate.autonomy.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
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
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import com.firstmate.autonomy.domain.model.DecisionCategory
import com.firstmate.autonomy.domain.model.DomainStatus
import com.firstmate.autonomy.ui.preview.ThemePreviews
import com.firstmate.autonomy.ui.theme.AutonomyAccents
import com.firstmate.autonomy.ui.theme.AutonomyTheme

/** Small pill that shows a project's lifecycle stage with a colored dot. */
@Composable
fun DomainStatusChip(
    status: DomainStatus,
    modifier: Modifier = Modifier,
) {
    val accent = status.accentColor()
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
    leading: @Composable (() -> Unit)? = null,
) {
    Surface(
        modifier = modifier,
        shape = MaterialTheme.shapes.small,
        color = MaterialTheme.colorScheme.surfaceVariant,
        contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
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

@Composable
fun DomainStatus.accentColor(): Color = when (this) {
    DomainStatus.PLANNING -> AutonomyAccents.planning()
    DomainStatus.IN_PROGRESS -> AutonomyAccents.inProgress()
    DomainStatus.COMPLETED -> AutonomyAccents.completed()
}

@ThemePreviews
@Composable
private fun StatusChipPreview() {
    AutonomyTheme(darkTheme = isSystemInDarkTheme()) {
        Row(
            modifier = Modifier.padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            DomainStatus.entries.forEach { DomainStatusChip(it) }
            Spacer(Modifier.width(4.dp))
            DecisionCategoryChip(DecisionCategory.FAMILY_DYNAMICS)
        }
    }
}
