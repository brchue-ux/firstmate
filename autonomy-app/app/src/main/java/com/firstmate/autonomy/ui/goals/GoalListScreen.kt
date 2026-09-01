package com.firstmate.autonomy.ui.goals

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Explore
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.firstmate.autonomy.domain.model.Goal
import com.firstmate.autonomy.ui.common.UiState
import com.firstmate.autonomy.ui.common.UiStateContent
import com.firstmate.autonomy.ui.components.AutonomyCard
import com.firstmate.autonomy.ui.components.EmptyState
import com.firstmate.autonomy.ui.components.GoalStatusChip
import com.firstmate.autonomy.ui.preview.PreviewData
import com.firstmate.autonomy.ui.preview.ThemePreviews
import com.firstmate.autonomy.ui.theme.AutonomyTheme
import java.time.LocalDate

/**
 * The plain list of goals.
 *
 * The space view is the good way to look at these; this is the way to change
 * them. Keeping creation and editing on ordinary screens means the canvas
 * never has to grow a keyboard.
 */
@Composable
fun GoalListRoute(
    onOpenGoal: (Long) -> Unit,
    onNewGoal: () -> Unit,
    modifier: Modifier = Modifier,
    viewModel: GoalListViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    GoalListScreen(
        state = state,
        today = viewModel.today,
        onOpenGoal = onOpenGoal,
        onNewGoal = onNewGoal,
        modifier = modifier,
    )
}

@Composable
fun GoalListScreen(
    state: UiState<List<Goal>>,
    today: LocalDate,
    onOpenGoal: (Long) -> Unit,
    onNewGoal: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(modifier.fillMaxSize()) {
        UiStateContent(state = state, modifier = Modifier.fillMaxSize()) { goals ->
            if (goals.isEmpty()) {
                EmptyState(
                    icon = Icons.Outlined.Explore,
                    title = "No goals yet",
                    message = "A goal is anything you are trying to keep up. Give it a few " +
                        "particulars and they become the things you tick.",
                    actionLabel = "New goal",
                    onAction = onNewGoal,
                )
            } else {
                LazyColumn(
                    contentPadding = PaddingValues(16.dp, 16.dp, 16.dp, 96.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(goals, key = { it.id }) { goal ->
                        GoalRow(goal = goal, today = today, onClick = { onOpenGoal(goal.id) })
                    }
                }
            }
        }
        ExtendedFloatingActionButton(
            onClick = onNewGoal,
            icon = { Icon(Icons.Filled.Add, contentDescription = null) },
            text = { Text("New goal") },
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(16.dp),
        )
    }
}

@Composable
private fun GoalRow(goal: Goal, today: LocalDate, onClick: () -> Unit) {
    AutonomyCard(modifier = Modifier.fillMaxWidth().clickable(onClick = onClick)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Text(goal.title, style = MaterialTheme.typography.titleSmall)
                Text(
                    text = summary(goal, today),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
            GoalStatusChip(goal.status)
        }
    }
}

private fun summary(goal: Goal, today: LocalDate): String {
    if (goal.particulars.isEmpty()) return "No particulars yet"
    val warm = (goal.warmth(today) * 100).toInt()
    val moons = goal.momentCount
    return "${goal.particulars.size} particulars · $warm% this week · " +
        "$moons ${if (moons == 1) "moment" else "moments"}"
}

@ThemePreviews
@Composable
private fun GoalListPreview() {
    AutonomyTheme {
        GoalListScreen(
            state = UiState.Success(PreviewData.goals),
            today = PreviewData.today,
            onOpenGoal = {},
            onNewGoal = {},
        )
    }
}
