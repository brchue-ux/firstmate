package com.firstmate.autonomy.ui.dashboard

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Balance
import androidx.compose.material.icons.outlined.Handyman
import androidx.compose.material.icons.outlined.SpaceDashboard
import androidx.compose.material.icons.outlined.TaskAlt
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.firstmate.autonomy.domain.model.Decision
import com.firstmate.autonomy.domain.model.HabitWithTodayStatus
import com.firstmate.autonomy.domain.model.ProjectDomain
import com.firstmate.autonomy.ui.common.UiState
import com.firstmate.autonomy.ui.common.UiStateContent
import com.firstmate.autonomy.ui.components.AutonomyCard
import com.firstmate.autonomy.ui.components.CollapsingScaffold
import com.firstmate.autonomy.ui.components.DomainStatusChip
import com.firstmate.autonomy.ui.components.EmptyState
import com.firstmate.autonomy.ui.components.InlineEmptyState
import com.firstmate.autonomy.ui.components.ProgressRing
import com.firstmate.autonomy.ui.components.SectionHeader
import com.firstmate.autonomy.ui.components.pressPhysics
import com.firstmate.autonomy.ui.preview.PreviewData
import com.firstmate.autonomy.ui.preview.ScreenPreviews
import com.firstmate.autonomy.ui.theme.AutonomyShape
import com.firstmate.autonomy.ui.theme.AutonomyTheme
import com.firstmate.autonomy.ui.util.formatRelative
import com.firstmate.autonomy.ui.util.weekdayAndDay
import java.time.LocalDate

/** Command centre: what is active, what was decided lately, and today's agency. */
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
    viewModel: DashboardViewModel = hiltViewModel(),
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

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun DashboardContent(
    uiState: UiState<DashboardState>,
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
    CollapsingScaffold(
        modifier = modifier,
        title = "Command Centre",
        subtitle = uiState.dataOrNull?.today?.weekdayAndDay(),
    ) { innerPadding, _ ->
        UiStateContent(state = uiState, modifier = Modifier.padding(innerPadding)) { state ->
            val overview = state.overview
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                item(key = "actions") {
                    QuickActions(
                        onNewProject = onNewProject,
                        onLogDecision = onLogDecision,
                        onDailyCheckIn = onDailyCheckIn,
                        modifier = Modifier.animateItem(),
                    )
                }

                if (state.isEmpty) {
                    item(key = "empty") {
                        EmptyState(
                            icon = Icons.Outlined.SpaceDashboard,
                            title = "A clean slate",
                            message = "Start a project you own, log a choice you made, or set " +
                                "the daily habits you will not trade away.",
                            contentPadding = PaddingValues(vertical = 40.dp, horizontal = 16.dp),
                        )
                    }
                    return@LazyColumn
                }

                item(key = "domains-header") {
                    SectionHeader(
                        title = "Active domains",
                        actionLabel = "See all".takeIf { overview.activeDomains.isNotEmpty() },
                        onActionClick = onSeeAllDomains
                            .takeIf { overview.activeDomains.isNotEmpty() },
                    )
                }
                if (overview.activeDomains.isEmpty()) {
                    item(key = "domains-empty") {
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
                    items(overview.activeDomains, key = { "domain-${it.id}" }) { domain ->
                        CompactDomainRow(
                            domain = domain,
                            onClick = { onDomainClick(domain.id) },
                            modifier = Modifier.animateItem(),
                        )
                    }
                }

                item(key = "habits-header") { SectionHeader(title = "Today's agency") }
                if (overview.todayHabits.isEmpty()) {
                    item(key = "habits-empty") {
                        InlineEmptyState(
                            "No habits tracked yet. Daily check-in sets up the first one.",
                        )
                    }
                } else {
                    item(key = "habits-card") {
                        TodayAgencyCard(
                            overview = overview,
                            onToggleHabit = onToggleHabit,
                            modifier = Modifier.animateItem(),
                        )
                    }
                }

                item(key = "decisions-header") {
                    SectionHeader(
                        title = "Recent decisions",
                        actionLabel = "See all".takeIf { overview.recentDecisions.isNotEmpty() },
                        onActionClick = onSeeAllDecisions
                            .takeIf { overview.recentDecisions.isNotEmpty() },
                    )
                }
                if (overview.recentDecisions.isEmpty()) {
                    item(key = "decisions-empty") {
                        InlineEmptyState("Nothing logged yet. The first entry is the hardest.")
                    }
                } else {
                    items(overview.recentDecisions, key = { "decision-${it.id}" }) { decision ->
                        CompactDecisionRow(
                            decision = decision,
                            today = state.today,
                            onClick = { onDecisionClick(decision.id) },
                            modifier = Modifier.animateItem(),
                        )
                    }
                }

                item(key = "tail") { Spacer(Modifier.height(24.dp)) }
            }
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
        horizontalArrangement = Arrangement.spacedBy(10.dp),
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
            label = "Check in",
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
    val interaction = remember { MutableInteractionSource() }
    FilledTonalButton(
        onClick = onClick,
        modifier = modifier.pressPhysics(interaction),
        interactionSource = interaction,
        shape = AutonomyShape.card,
        contentPadding = PaddingValues(vertical = 14.dp, horizontal = 8.dp),
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
private fun TodayAgencyCard(
    overview: com.firstmate.autonomy.domain.model.DashboardOverview,
    onToggleHabit: (Long, Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    AutonomyCard(modifier = modifier) {
        Column(Modifier.padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                ProgressRing(
                    progress = if (overview.todayHabits.isEmpty()) {
                        0f
                    } else {
                        overview.todayCompletedCount.toFloat() / overview.todayHabits.size
                    },
                    size = 66.dp,
                    strokeWidth = 8.dp,
                    color = MaterialTheme.colorScheme.secondary,
                    contentDescriptionText = "${overview.todayCompletedCount} of " +
                        "${overview.todayHabits.size} habits done today",
                )
                Spacer(Modifier.width(16.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        text = "${overview.todayCompletedCount} of " +
                            "${overview.todayHabits.size} done today",
                        style = MaterialTheme.typography.titleMedium,
                    )
                    Text(
                        text = "${(overview.weeklyHabitRate * 100).toInt()}% over the last week",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Spacer(Modifier.height(8.dp))
            overview.todayHabits.forEach { entry ->
                TodayHabitRow(
                    entry = entry,
                    onToggle = { checked -> onToggleHabit(entry.habit.id, checked) },
                )
            }
        }
    }
}

@Composable
private fun CompactDomainRow(
    domain: ProjectDomain,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    AutonomyCard(modifier = modifier.clickable(onClick = onClick), elevation = 6.dp) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ProgressRing(
                progress = domain.progress,
                size = 54.dp,
                strokeWidth = 7.dp,
                color = AutonomyTheme.accents.forStatus(domain.status),
                contentDescriptionText = "${domain.title}, " +
                    "${domain.progressPercent} percent complete",
            )
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    text = domain.title,
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 1,
                )
                Spacer(Modifier.height(6.dp))
                DomainStatusChip(domain.status)
            }
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
        Checkbox(
            checked = entry.isCompletedToday,
            onCheckedChange = onToggle,
            colors = CheckboxDefaults.colors(
                checkedColor = MaterialTheme.colorScheme.secondary,
                checkmarkColor = MaterialTheme.colorScheme.onSecondary,
            ),
        )
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
    AutonomyCard(modifier = modifier.clickable(onClick = onClick), elevation = 6.dp) {
        Column(Modifier.padding(16.dp)) {
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
            uiState = UiState.Success(
                DashboardState(today = PreviewData.today, overview = PreviewData.dashboard),
            ),
            onNewProject = {}, onLogDecision = {}, onDailyCheckIn = {},
            onDomainClick = {}, onSeeAllDomains = {}, onSeeAllDecisions = {},
            onDecisionClick = {}, onToggleHabit = { _, _ -> },
        )
    }
}

@ScreenPreviews
@Composable
private fun DashboardEmptyPreview() {
    AutonomyTheme {
        DashboardContent(
            uiState = UiState.Success(
                DashboardState(today = PreviewData.today, overview = PreviewData.emptyDashboard),
            ),
            onNewProject = {}, onLogDecision = {}, onDailyCheckIn = {},
            onDomainClick = {}, onSeeAllDomains = {}, onSeeAllDecisions = {},
            onDecisionClick = {}, onToggleHabit = { _, _ -> },
        )
    }
}

@ScreenPreviews
@Composable
private fun DashboardLoadingPreview() {
    AutonomyTheme {
        DashboardContent(
            uiState = UiState.Loading,
            onNewProject = {}, onLogDecision = {}, onDailyCheckIn = {},
            onDomainClick = {}, onSeeAllDomains = {}, onSeeAllDecisions = {},
            onDecisionClick = {}, onToggleHabit = { _, _ -> },
        )
    }
}
