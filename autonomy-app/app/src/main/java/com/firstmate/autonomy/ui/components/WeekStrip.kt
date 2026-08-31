package com.firstmate.autonomy.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import com.firstmate.autonomy.domain.model.DayStatus
import com.firstmate.autonomy.ui.preview.PreviewData
import com.firstmate.autonomy.ui.preview.ThemePreviews
import com.firstmate.autonomy.ui.theme.AutonomyTheme
import com.firstmate.autonomy.ui.util.weekdayInitial
import java.time.LocalDate

/**
 * Seven filled-or-hollow dots, oldest on the left, with the current day ringed.
 *
 * Read-only on purpose: past days are edited nowhere in this app, so the strip
 * is a record rather than a control. The whole row is one accessibility node.
 */
@Composable
fun WeekStrip(
    days: List<DayStatus>,
    today: LocalDate,
    modifier: Modifier = Modifier,
) {
    val summary = days.count { it.isCompleted }
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clearAndSetSemantics {
                contentDescription = "$summary of ${days.size} days completed this week"
            },
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        days.forEach { day ->
            DayDot(day = day, isToday = day.date == today, modifier = Modifier.weight(1f))
        }
    }
}

@Composable
private fun DayDot(
    day: DayStatus,
    isToday: Boolean,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = day.date.weekdayInitial(),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(4.dp))
        Surface(
            shape = CircleShape,
            color = if (day.isCompleted) {
                MaterialTheme.colorScheme.primary
            } else {
                MaterialTheme.colorScheme.surfaceVariant
            },
            border = if (isToday) {
                BorderStroke(2.dp, MaterialTheme.colorScheme.primary)
            } else {
                null
            },
            modifier = Modifier.size(28.dp),
        ) {
            if (day.isCompleted) {
                Icon(
                    imageVector = Icons.Filled.Check,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onPrimary,
                    modifier = Modifier.padding(6.dp),
                )
            }
        }
    }
}

@ThemePreviews
@Composable
private fun WeekStripPreview() {
    AutonomyTheme {
        Column(
            Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            PreviewData.habitConsistency.forEach {
                WeekStrip(days = it.days, today = PreviewData.today)
            }
        }
    }
}
