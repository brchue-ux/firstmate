package com.firstmate.autonomy.ui.dashboard

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Balance
import androidx.compose.material.icons.outlined.Handyman
import androidx.compose.material.icons.outlined.SpaceDashboard
import androidx.compose.material.icons.outlined.TaskAlt
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.firstmate.autonomy.di.AutonomyViewModelFactory
import com.firstmate.autonomy.domain.model.Decision
import com.firstmate.autonomy.domain.model.HabitWithTodayStatus
import com.firstmate.autonomy.domain.model.ProjectDomain
import com.firstmate.autonomy.ui.components.DomainStatusChip
import com.firstmate.autonomy.ui.components.EmptyState
import com.firstmate.autonomy.ui.components.InlineEmptyState
import com.firstmate.autonomy.ui.components.LabeledProgress
import com.firstmate.autonomy.ui.components.SectionHeader
import com.firstmate.autonomy.ui.preview.PreviewData
import com.firstmate.autonomy.ui.preview.ScreenPreviews
import com.firstmate.autonomy.ui.theme.AutonomyTheme
import com.firstmate.autonomy.ui.util.formatRelative
import com.firstmate.autonomy.ui.util.weekdayAndDay
import java.time.LocalDate

/** Home screen: what is active, what was decided lately, and today's check-in. */
@Composable
fun DashboardScreen(
    onNewProject: () -> Unit,
    onLogDecision: () -> Unit,
    onDailyCheckIn: () -> Unit,
    onDomainClick: (Long) -> Unit,
    onSeeAllDomains: () -> Unit,
    onSeeAllDecisions: () -> Unit,
    onDecisionClick: (Long) -> Unit,
    modifier: Modifier = Modifier,
    viewModel: DashboardViewModel = viewModel(factory = AutonomyViewModelFactory.Factory),
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()

    LifecycleResumeEffect(Unit) {
        viewModel.refreshToday()
        onPauseOrDispose { }
    }

    DashboardContent(
        uiState = uiState,
        onNewProject = onNewProject,
        onLogDecision = onLogDecision,
        onDailyCheckIn = onDailyCheckIn,
        onDomainClick = onDomainClick,
        onSeeAllDomains = onSeeAllDomains,
        onSeeAllDecisions = onSeeAllDecisions,
        onDecisionClick = onDecisionClick,
        onToggleHabit = viewModel::setTodayCompleted,
        modifier = modifier,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DashboardContent(
    uiState: DashboardUiState,
    onNewProject: () -> Unit,
    onLogDecision: () -> Unit,
    onDailyCheckIn: () -> Unit,
    onDomainClick: (Long) -> Unit,
    onSeeAllDomains: () -> Unit,
    onSeeAllDecisions: () -> Unit,
    onDecisionClick: (Long) -> Unit,
    onToggleHabit: (Long, Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val overview = uiState.overview

    Scaffold(
        modifier = modifier,
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("Autonomy")
                        Text(
                            text = uiState.today.weekdayAndDay(),
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
            )
        },
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                QuickActions(
                    onNewProject = onNewProject,
                    onLogDecision = onLogDecision,
                    onDailyCheckIn = onDailyCheckIn,
                )
            }

            if (uiState.isEmpty) {
                item {
                    EmptyState(
                        icon = Icons.Outlined.SpaceDashboard,
                        title = "A clean slate",
                        message = "Start a project you own, log a choice you made, or set the " +
                            "daily habits you will not trade away.",
                        contentPadding = PaddingValues(vertical = 40.dp, horizontal = 16.dp),
                    )
                }
                return@LazyColumn
            }

            item {
                SectionHeader(
                    title = "Active domains",
                    actionLabel = if (overview.activeDomains.isNotEmpty()) "See all" else null,
                    onActionClick = onSeeAllDomains.takeIf { overview.activeDomains.isNotEmpty() },
                )
            }
            if (overview.activeDomains.isEmpty()) {
                item {
                    InlineEmptyState(
                        if (overview.completedDomainCount > 0) {
                            "Everything is finished. ${overview.completedDomainCount} " +
                                "completed project(s) are in My Domains."
                        } else {
                            "No active projects. Add one to see its progress here."
                        },
                    )
                }
            } else {
                item {
                    LabeledProgress(
                        label = "Across ${overview.activeDomains.size} active project(s)",
                        progress = overview.averageDomainProgress,
                        trailingText = "${(overview.averageDomainProgress * 100).toInt()}%",
                    )
                }
                items(overview.activeDomains, key = { "domain-${it.id}" }) { domain ->
                    CompactDomainRow(domain = domain, onClick = { onDomainClick(domain.id) })
                }
            }

            item { Spacer(Modifier.height(4.dp)) }
            item { SectionHeader(title = "Today's check-in") }
            if (overview.todayHabits.isEmpty()) {
                item {
                    InlineEmptyState(
                        "No habits tracked yet. Daily check-in sets up the first one.",
                    )
                }
            } else {
                item {
                    Text(
                        text = "${overview.todayCompletedCount} of " +
                            "${overview.todayHabits.size} done · " +
                            "${(overview.weeklyHabitRate * 100).toInt()}% over the last week",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                items(overview.todayHabits, key = { "habit-${it.habit.id}" }) { entry ->
                    TodayHabitRow(
                        entry = entry,
                        onToggle = { checked -> onToggleHabit(entry.habit.id, checked) },
                    )
                }
            }

            item { Spacer(Modifier.height(4.dp)) }
            item {
                SectionHeader(
                    title = "Recent decisions",
                    actionLabel = if (overview.recentDecisions.isNotEmpty()) "See all" else null,
                    onActionClick = onSeeAllDecisions
                        .takeIf { overview.recentDecisions.isNotEmpty() },
                )
            }
            if (overview.recentDecisions.isEmpty()) {
                item {
                    InlineEmptyState("Nothing logged yet. The first entry is the hardest.")
                }
            } else {
                items(overview.recentDecisions, key = { "decision-${it.id}" }) { decision ->
                    CompactDecisionRow(
                        decision = decision,
                        today = uiState.today,
                        onClick = { onDecisionClick(decision.id) },
                    )
                }
            }

            item { Spacer(Modifier.height(24.dp)) }
        }
    }
}

@Composable
private fun QuickActions(
    onNewProject: () -> Unit,
    onLogDecision: () -> Unit,
    onDailyCheckIn: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        QuickAction(
            label = "New project",
            icon = Icons.Outlined.Handyman,
            onClick = onNewProject,
            modifier = Modifier.weight(1f),
        )
        QuickAction(
            label = "Log decision",
            icon = Icons.Outlined.Balance,
            onClick = onLogDecision,
            modifier = Modifier.weight(1f),
        )
        QuickAction(
            label = "Daily check-in",
            icon = Icons.Outlined.TaskAlt,
            onClick = onDailyCheckIn,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun QuickAction(
    label: String,
    icon: ImageVector,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    FilledTonalButton(
        onClick = onClick,
        modifier = modifier,
        contentPadding = PaddingValues(vertical = 12.dp, horizontal = 8.dp),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(20.dp))
            Spacer(Modifier.height(6.dp))
            Text(
                text = label,
                style = MaterialTheme.typography.labelMedium,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun CompactDomainRow(
    domain: ProjectDomain,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Card(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
        ),
    ) {
        Column(Modifier.padding(14.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = domain.title,
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 1,
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.height(8.dp))
                DomainStatusChip(domain.status)
            }
            Spacer(Modifier.height(10.dp))
            LabeledProgress(
                label = "Milestones",
                progress = domain.progress,
                trailingText = "${domain.completedMilestoneCount} of ${domain.milestoneCount}",
                accessibilityText = "${domain.title}, ${domain.progressPercent} percent complete",
            )
        }
    }
}

@Composable
private fun TodayHabitRow(
    entry: HabitWithTodayStatus,
    onToggle: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(checked = entry.isCompletedToday, onCheckedChange = onToggle)
        Text(
            text = entry.habit.name,
            style = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun CompactDecisionRow(
    decision: Decision,
    today: LocalDate,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Card(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
        ),
    ) {
        Column(Modifier.padding(14.dp)) {
            Text(text = decision.title, style = MaterialTheme.typography.titleMedium, maxLines = 2)
            Spacer(Modifier.height(4.dp))
            Text(
                text = "${decision.date.formatRelative(today)} · ${decision.category.label}",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@ScreenPreviews
@Composable
private fun DashboardPreview() {
    AutonomyTheme {
        DashboardContent(
            uiState = DashboardUiState(
                isLoading = false,
                today = PreviewData.today,
                overview = PreviewData.dashboard,
            ),
            onNewProject = {},
            onLogDecision = {},
            onDailyCheckIn = {},
            onDomainClick = {},
            onSeeAllDomains = {},
            onSeeAllDecisions = {},
            onDecisionClick = {},
            onToggleHabit = { _, _ -> },
        )
    }
}

@ScreenPreviews
@Composable
private fun DashboardEmptyPreview() {
    AutonomyTheme {
        DashboardContent(
            uiState = DashboardUiState(
                isLoading = false,
                today = PreviewData.today,
                overview = PreviewData.emptyDashboard,
            ),
            onNewProject = {},
            onLogDecision = {},
            onDailyCheckIn = {},
            onDomainClick = {},
            onSeeAllDomains = {},
            onSeeAllDecisions = {},
            onDecisionClick = {},
            onToggleHabit = { _, _ -> },
        )
    }
}
