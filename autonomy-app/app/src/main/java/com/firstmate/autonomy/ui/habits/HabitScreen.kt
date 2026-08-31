package com.firstmate.autonomy.ui.habits

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.Celebration
import androidx.compose.material.icons.outlined.NotificationsOff
import androidx.compose.material.icons.outlined.TaskAlt
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.firstmate.autonomy.domain.model.HabitConsistency
import com.firstmate.autonomy.ui.common.UiState
import com.firstmate.autonomy.ui.common.UiStateContent
import com.firstmate.autonomy.ui.components.AutonomyCard
import com.firstmate.autonomy.ui.components.AutonomyTextField
import com.firstmate.autonomy.ui.components.CollapsingScaffold
import com.firstmate.autonomy.ui.components.ConfettiEffect
import com.firstmate.autonomy.ui.components.EmptyState
import com.firstmate.autonomy.ui.components.ProgressRing
import com.firstmate.autonomy.ui.components.WeekStrip
import com.firstmate.autonomy.ui.components.pressPhysics
import com.firstmate.autonomy.ui.components.rememberCelebration
import com.firstmate.autonomy.ui.preview.PreviewData
import com.firstmate.autonomy.ui.preview.ScreenPreviews
import com.firstmate.autonomy.ui.theme.AutonomyTheme
import com.firstmate.autonomy.ui.util.weekdayAndDay
import kotlinx.coroutines.flow.collectLatest
import java.time.LocalDate

/** "Boundary & Agency Tracker": today's check-in plus weekly and monthly streaks. */
@Composable
fun HabitScreen(
    modifier: Modifier = Modifier,
    viewModel: HabitViewModel = hiltViewModel(),
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val celebrationsOn = uiState.dataOrNull?.celebrationsEnabled ?: true
    val celebration = rememberCelebration(enabled = celebrationsOn)
    var celebrating by remember { mutableStateOf(false) }

    // Coming back to the app after midnight must not tick yesterday's box.
    LifecycleResumeEffect(Unit) {
        viewModel.refreshToday()
        onPauseOrDispose { }
    }

    LaunchedCelebration(viewModel) {
        celebration.tap()
        celebrating = true
    }

    Box(modifier) {
        HabitContent(
            uiState = uiState,
            onToggleToday = viewModel::setTodayCompleted,
            onToggleCelebrations = viewModel::setCelebrationsEnabled,
            onArchiveHabit = viewModel::archiveHabit,
            onShowAddHabit = viewModel::showAddHabit,
            onDismissAddHabit = viewModel::dismissAddHabit,
            onNewHabitNameChange = viewModel::onNewHabitNameChange,
            onNewHabitDescriptionChange = viewModel::onNewHabitDescriptionChange,
            onSaveNewHabit = viewModel::saveNewHabit,
        )
        ConfettiEffect(
            visible = celebrating,
            enabled = uiState.dataOrNull?.celebrationsEnabled ?: true,
            onFinished = { celebrating = false },
        )
    }
}

@Composable
private fun LaunchedCelebration(viewModel: HabitViewModel, onEvent: () -> Unit) {
    androidx.compose.runtime.LaunchedEffect(viewModel) {
        viewModel.events.collectLatest { onEvent() }
    }
}

@Composable
fun HabitContent(
    uiState: UiState<HabitScreenState>,
    onToggleToday: (Long, Boolean) -> Unit,
    onToggleCelebrations: (Boolean) -> Unit,
    onArchiveHabit: (Long) -> Unit,
    onShowAddHabit: () -> Unit,
    onDismissAddHabit: () -> Unit,
    onNewHabitNameChange: (String) -> Unit,
    onNewHabitDescriptionChange: (String) -> Unit,
    onSaveNewHabit: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state = uiState.dataOrNull
    CollapsingScaffold(
        modifier = modifier,
        title = "Boundaries",
        actions = {
            val on = state?.celebrationsEnabled ?: true
            IconButton(onClick = { onToggleCelebrations(!on) }) {
                Icon(
                    imageVector = if (on) {
                        Icons.Outlined.Celebration
                    } else {
                        Icons.Outlined.NotificationsOff
                    },
                    contentDescription = if (on) {
                        "Turn off celebrations"
                    } else {
                        "Turn on celebrations"
                    },
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        subtitle = state?.takeIf { !it.isEmpty }?.let {
            "${it.completedToday} of ${it.habits.size} done today" +
                if (it.bestStreak > 1) " · best streak ${it.bestStreak} days" else ""
        },
        floatingActionButton = {
            val interaction = remember { MutableInteractionSource() }
            ExtendedFloatingActionButton(
                onClick = onShowAddHabit,
                modifier = Modifier.pressPhysics(interaction),
                interactionSource = interaction,
                containerColor = MaterialTheme.colorScheme.primaryContainer,
                contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                icon = { Icon(Icons.Filled.Add, contentDescription = null) },
                text = { Text("New habit") },
            )
        },
    ) { innerPadding ->
        UiStateContent(state = uiState, modifier = Modifier.padding(innerPadding)) { current ->
            if (current.isEmpty) {
                EmptyState(
                    icon = Icons.Outlined.TaskAlt,
                    title = "Nothing tracked yet",
                    message = "Add the small daily things you refuse to trade away - solo " +
                        "time, practice, one boundary held. Two or three is plenty.",
                    actionLabel = "New habit",
                    onAction = onShowAddHabit,
                )
            } else {
                HabitList(
                    state = current,
                    onToggleToday = onToggleToday,
                    onArchiveHabit = onArchiveHabit,
                )
            }
        }
    }

    if (state?.newHabit?.isVisible == true) {
        AddHabitDialog(
            draft = state.newHabit,
            onNameChange = onNewHabitNameChange,
            onDescriptionChange = onNewHabitDescriptionChange,
            onSave = onSaveNewHabit,
            onDismiss = onDismissAddHabit,
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun HabitList(
    state: HabitScreenState,
    onToggleToday: (Long, Boolean) -> Unit,
    onArchiveHabit: (Long) -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 104.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item(key = "today") { TodaySummary(state, Modifier.animateItem()) }
        items(state.habits, key = { it.habit.id }) { consistency ->
            HabitCard(
                consistency = consistency,
                today = state.today,
                onToggleToday = { checked -> onToggleToday(consistency.habit.id, checked) },
                onArchive = { onArchiveHabit(consistency.habit.id) },
                modifier = Modifier.animateItem(),
            )
        }
    }
}

@Composable
private fun TodaySummary(
    state: HabitScreenState,
    modifier: Modifier = Modifier,
) {
    AutonomyCard(
        modifier = modifier,
        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
    ) {
        Row(
            modifier = Modifier.padding(20.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ProgressRing(
                progress = state.todayProgress,
                size = 84.dp,
                strokeWidth = 10.dp,
                color = MaterialTheme.colorScheme.secondary,
                contentDescriptionText = "Today, ${state.completedToday} of " +
                    "${state.habits.size} habits done",
            )
            Spacer(Modifier.width(18.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    text = state.today.weekdayAndDay(),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "${state.completedToday} of ${state.habits.size} done today",
                    style = MaterialTheme.typography.titleMedium,
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    text = "${state.monthlyRatePercent}% over the last 30 days",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/** One habit: today's checkbox, the week at a glance, and the monthly rate. */
@Composable
fun HabitCard(
    consistency: HabitConsistency,
    today: LocalDate,
    onToggleToday: (Boolean) -> Unit,
    onArchive: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val isDoneToday = consistency.days.lastOrNull()?.isCompleted == true
    AutonomyCard(modifier = modifier) {
        Column(Modifier.padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(
                    checked = isDoneToday,
                    onCheckedChange = onToggleToday,
                    colors = CheckboxDefaults.colors(
                        checkedColor = MaterialTheme.colorScheme.secondary,
                        checkmarkColor = MaterialTheme.colorScheme.onSecondary,
                    ),
                )
                Column(Modifier.weight(1f)) {
                    Text(
                        text = consistency.habit.name,
                        style = MaterialTheme.typography.titleMedium,
                    )
                    if (consistency.habit.description.isNotBlank()) {
                        Text(
                            text = consistency.habit.description,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                IconButton(onClick = onArchive) {
                    Icon(
                        Icons.Outlined.Archive,
                        contentDescription = "Stop tracking ${consistency.habit.name}",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Spacer(Modifier.height(14.dp))
            WeekStrip(days = consistency.thisWeek(), today = today)
            Spacer(Modifier.height(14.dp))
            Text(
                text = "${consistency.completedCount} of ${consistency.days.size} days " +
                    "· ${consistency.ratePercent}%" +
                    if (consistency.currentStreak > 1) {
                        " · ${consistency.currentStreak}-day streak"
                    } else {
                        ""
                    },
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun AddHabitDialog(
    draft: NewHabitDraft,
    onNameChange: (String) -> Unit,
    onDescriptionChange: (String) -> Unit,
    onSave: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        shape = MaterialTheme.shapes.large,
        title = { Text("New daily habit") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                AutonomyTextField(
                    label = "Habit",
                    value = draft.name,
                    onValueChange = onNameChange,
                    placeholder = "Two hours of solo time",
                )
                AutonomyTextField(
                    label = "Note (optional)",
                    value = draft.description,
                    onValueChange = onDescriptionChange,
                    placeholder = "What counts as done?",
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onSave, enabled = draft.canSave) { Text("Add") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@ScreenPreviews
@Composable
private fun HabitScreenPreview() {
    AutonomyTheme {
        HabitContent(
            uiState = UiState.Success(
                HabitScreenState(
                    today = PreviewData.today,
                    habits = PreviewData.habitConsistency,
                ),
            ),
            onToggleToday = { _, _ -> },
            onToggleCelebrations = {},
            onArchiveHabit = {},
            onShowAddHabit = {},
            onDismissAddHabit = {},
            onNewHabitNameChange = {},
            onNewHabitDescriptionChange = {},
            onSaveNewHabit = {},
        )
    }
}

@ScreenPreviews
@Composable
private fun HabitScreenEmptyPreview() {
    AutonomyTheme {
        HabitContent(
            uiState = UiState.Success(HabitScreenState(today = PreviewData.today)),
            onToggleToday = { _, _ -> },
            onToggleCelebrations = {},
            onArchiveHabit = {},
            onShowAddHabit = {},
            onDismissAddHabit = {},
            onNewHabitNameChange = {},
            onNewHabitDescriptionChange = {},
            onSaveNewHabit = {},
        )
    }
}
