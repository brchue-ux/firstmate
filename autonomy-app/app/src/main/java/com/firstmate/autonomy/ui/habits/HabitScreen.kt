package com.firstmate.autonomy.ui.habits

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.TaskAlt
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.firstmate.autonomy.di.AutonomyViewModelFactory
import com.firstmate.autonomy.domain.model.HabitConsistency
import com.firstmate.autonomy.ui.components.AutonomyTextField
import com.firstmate.autonomy.ui.components.EmptyState
import com.firstmate.autonomy.ui.components.LabeledProgress
import com.firstmate.autonomy.ui.components.WeekStrip
import com.firstmate.autonomy.ui.preview.PreviewData
import com.firstmate.autonomy.ui.preview.ScreenPreviews
import com.firstmate.autonomy.ui.theme.AutonomyTheme
import com.firstmate.autonomy.ui.util.weekdayAndDay
import java.time.LocalDate

/** "Boundary & Habit Tracker": today's check-in, plus weekly and monthly consistency. */
@Composable
fun HabitScreen(
    modifier: Modifier = Modifier,
    viewModel: HabitViewModel = viewModel(factory = AutonomyViewModelFactory.Factory),
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()

    // Coming back to the app after midnight must not tick yesterday's box.
    LifecycleResumeEffect(Unit) {
        viewModel.refreshToday()
        onPauseOrDispose { }
    }

    HabitContent(
        uiState = uiState,
        onToggleToday = viewModel::setTodayCompleted,
        onArchiveHabit = viewModel::archiveHabit,
        onShowAddHabit = viewModel::showAddHabit,
        onDismissAddHabit = viewModel::dismissAddHabit,
        onNewHabitNameChange = viewModel::onNewHabitNameChange,
        onNewHabitDescriptionChange = viewModel::onNewHabitDescriptionChange,
        onSaveNewHabit = viewModel::saveNewHabit,
        modifier = modifier,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HabitContent(
    uiState: HabitUiState,
    onToggleToday: (Long, Boolean) -> Unit,
    onArchiveHabit: (Long) -> Unit,
    onShowAddHabit: () -> Unit,
    onDismissAddHabit: () -> Unit,
    onNewHabitNameChange: (String) -> Unit,
    onNewHabitDescriptionChange: (String) -> Unit,
    onSaveNewHabit: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Scaffold(
        modifier = modifier,
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        topBar = { TopAppBar(title = { Text("Boundaries & Habits") }) },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = onShowAddHabit,
                icon = { Icon(Icons.Filled.Add, contentDescription = null) },
                text = { Text("New habit") },
            )
        },
    ) { innerPadding ->
        Box(Modifier.padding(innerPadding)) {
            when {
                uiState.isLoading -> Unit

                uiState.isEmpty -> EmptyState(
                    icon = Icons.Outlined.TaskAlt,
                    title = "Nothing tracked yet",
                    message = "Add the small daily things you refuse to trade away - solo time, " +
                        "practice, one boundary held. Two or three is plenty.",
                    actionLabel = "New habit",
                    onAction = onShowAddHabit,
                )

                else -> LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(
                        start = 16.dp,
                        end = 16.dp,
                        top = 8.dp,
                        bottom = 96.dp,
                    ),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    item { TodaySummary(uiState) }
                    items(uiState.habits, key = { it.habit.id }) { consistency ->
                        HabitCard(
                            consistency = consistency,
                            today = uiState.today,
                            onToggleToday = { checked ->
                                onToggleToday(consistency.habit.id, checked)
                            },
                            onArchive = { onArchiveHabit(consistency.habit.id) },
                        )
                    }
                }
            }
        }
    }

    if (uiState.newHabit.isVisible) {
        AddHabitDialog(
            draft = uiState.newHabit,
            onNameChange = onNewHabitNameChange,
            onDescriptionChange = onNewHabitDescriptionChange,
            onSave = onSaveNewHabit,
            onDismiss = onDismissAddHabit,
        )
    }
}

@Composable
private fun TodaySummary(
    uiState: HabitUiState,
    modifier: Modifier = Modifier,
) {
    Card(
        modifier = modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.secondaryContainer,
            contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
        ),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text(
                text = uiState.today.weekdayAndDay(),
                style = MaterialTheme.typography.labelMedium,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = "${uiState.completedToday} of ${uiState.habits.size} done today",
                style = MaterialTheme.typography.titleMedium,
            )
            Spacer(Modifier.height(14.dp))
            LabeledProgress(
                label = "Last 30 days",
                progress = uiState.monthlyRatePercent / 100f,
                trailingText = "${uiState.monthlyRatePercent}%",
                accessibilityText = "Last 30 days, ${uiState.monthlyRatePercent} percent " +
                    "of check-ins completed",
            )
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
    Card(
        modifier = modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
        ),
    ) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(checked = isDoneToday, onCheckedChange = onToggleToday)
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
            Spacer(Modifier.height(12.dp))
            WeekStrip(days = consistency.thisWeek(), today = today)
            Spacer(Modifier.height(12.dp))
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
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@ScreenPreviews
@Composable
private fun HabitScreenPreview() {
    AutonomyTheme {
        HabitContent(
            uiState = HabitUiState(
                isLoading = false,
                today = PreviewData.today,
                habits = PreviewData.habitConsistency,
            ),
            onToggleToday = { _, _ -> },
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
            uiState = HabitUiState(isLoading = false, today = PreviewData.today),
            onToggleToday = { _, _ -> },
            onArchiveHabit = {},
            onShowAddHabit = {},
            onDismissAddHabit = {},
            onNewHabitNameChange = {},
            onNewHabitDescriptionChange = {},
            onSaveNewHabit = {},
        )
    }
}
