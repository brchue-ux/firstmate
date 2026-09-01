package com.firstmate.autonomy.ui.today

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.Explore
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedIconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.firstmate.autonomy.domain.model.TodayItem
import com.firstmate.autonomy.domain.model.TodayOverview
import com.firstmate.autonomy.domain.model.week
import com.firstmate.autonomy.ui.common.UiState
import com.firstmate.autonomy.ui.common.UiStateContent
import com.firstmate.autonomy.ui.components.AutonomyCard
import com.firstmate.autonomy.ui.components.EmptyState
import com.firstmate.autonomy.ui.components.ProgressRing
import com.firstmate.autonomy.ui.components.SectionHeader
import com.firstmate.autonomy.ui.components.WeekStrip
import com.firstmate.autonomy.ui.preview.PreviewData
import com.firstmate.autonomy.ui.preview.ThemePreviews
import com.firstmate.autonomy.ui.theme.AutonomyTheme
import java.time.LocalDate

/**
 * Today lists particulars, not goals.
 *
 * A particular is the thing you actually tick, so listing goals here would put
 * one more tap in front of every log on the screen whose whole job is to make
 * logging fast.
 */
@Composable
fun TodayRoute(
    onOpenGoal: (Long) -> Unit,
    modifier: Modifier = Modifier,
    viewModel: TodayViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    TodayScreen(
        state = state,
        today = viewModel.today,
        onSetDone = viewModel::setDone,
        onOpenGoal = onOpenGoal,
        modifier = modifier,
    )
}

@Composable
fun TodayScreen(
    state: UiState<TodayOverview>,
    today: LocalDate,
    onSetDone: (Long, Boolean) -> Unit,
    onOpenGoal: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    UiStateContent(state = state, modifier = modifier.fillMaxSize()) { overview ->
        if (!overview.hasAnything) {
            EmptyState(
                icon = Icons.Outlined.Explore,
                title = "Nothing to tick yet",
                message = "Add a goal and give it a particular or two. Those are the things " +
                    "you check off each day.",
            )
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                item { TodayHeader(overview) }
                item { SectionHeader(title = "Today") }
                items(overview.items, key = { it.particular.id }) { item ->
                    TodayRow(
                        item = item,
                        today = today,
                        onToggle = { onSetDone(item.particular.id, !item.isDoneToday) },
                        onOpenGoal = { onOpenGoal(item.goalId) },
                    )
                }
            }
        }
    }
}

@Composable
private fun TodayHeader(overview: TodayOverview) {
    AutonomyCard {
        Row(
            modifier = Modifier.fillMaxWidth().padding(4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            ProgressRing(
                progress = overview.todayRate,
                label = "${overview.doneToday}/${overview.items.size}",
                size = 88.dp,
                contentDescriptionText = "${overview.doneToday} of ${overview.items.size} " +
                    "particulars ticked today",
            )
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Today's agency", style = MaterialTheme.typography.titleMedium)
                Text(
                    text = "${overview.goalCount} goals · ${overview.momentCount} moments named",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (overview.needingAttention.isNotEmpty()) {
                    Text(
                        text = "Coldest: ${overview.needingAttention.first().particular.title}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun TodayRow(
    item: TodayItem,
    today: LocalDate,
    onToggle: () -> Unit,
    onOpenGoal: () -> Unit,
) {
    AutonomyCard {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Text(item.particular.title, style = MaterialTheme.typography.titleSmall)
                Text(
                    text = "${item.goalTitle} · ${item.condition.label}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (item.isDoneToday) {
                FilledIconButton(
                    onClick = onToggle,
                    colors = IconButtonDefaults.filledIconButtonColors(
                        containerColor = MaterialTheme.colorScheme.primaryContainer,
                    ),
                ) {
                    Icon(Icons.Filled.Check, contentDescription = "Ticked today")
                }
            } else {
                OutlinedIconButton(onClick = onToggle) {
                    Icon(Icons.Filled.Check, contentDescription = "Tick today")
                }
            }
        }
        WeekStrip(
            days = item.particular.week(today),
            today = today,
            modifier = Modifier.padding(top = 10.dp),
        )
    }
}

@ThemePreviews
@Composable
private fun TodayScreenPreview() {
    AutonomyTheme {
        TodayScreen(
            state = UiState.Success(PreviewData.todayOverview),
            today = PreviewData.today,
            onSetDone = { _, _ -> },
            onOpenGoal = {},
        )
    }
}

@ThemePreviews
@Composable
private fun TodayEmptyPreview() {
    AutonomyTheme {
        TodayScreen(
            state = UiState.Success(PreviewData.emptyOverview),
            today = PreviewData.today,
            onSetDone = { _, _ -> },
            onOpenGoal = {},
        )
    }
}
