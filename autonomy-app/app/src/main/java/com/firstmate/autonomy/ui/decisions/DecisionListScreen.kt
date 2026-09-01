package com.firstmate.autonomy.ui.decisions

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.outlined.Balance
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.firstmate.autonomy.domain.model.Decision
import com.firstmate.autonomy.ui.common.UiState
import com.firstmate.autonomy.ui.common.UiStateContent
import com.firstmate.autonomy.ui.components.AutonomyCard
import com.firstmate.autonomy.ui.components.CollapsingScaffold
import com.firstmate.autonomy.ui.components.DecisionCategoryChip
import com.firstmate.autonomy.ui.components.EmptyState
import com.firstmate.autonomy.ui.components.ExpandableContent
import com.firstmate.autonomy.ui.components.LabelChip
import com.firstmate.autonomy.ui.components.pressPhysics
import com.firstmate.autonomy.ui.preview.PreviewData
import com.firstmate.autonomy.ui.preview.ScreenPreviews
import com.firstmate.autonomy.ui.theme.AutonomyTheme
import com.firstmate.autonomy.ui.util.formatFull

/** "Decision Log": every choice made, owned and reflected on. */
@Composable
fun DecisionListScreen(
    onDecisionClick: (Long) -> Unit,
    onCreateDecision: () -> Unit,
    modifier: Modifier = Modifier,
    viewModel: DecisionListViewModel = hiltViewModel(),
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    DecisionListContent(
        uiState = uiState,
        onDecisionClick = onDecisionClick,
        onCreateDecision = onCreateDecision,
        onToggleExpanded = viewModel::toggleExpanded,
        modifier = modifier,
    )
}

@Composable
fun DecisionListContent(
    uiState: UiState<DecisionListState>,
    onDecisionClick: (Long) -> Unit,
    onCreateDecision: () -> Unit,
    onToggleExpanded: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    val state = uiState.dataOrNull
    CollapsingScaffold(
        modifier = modifier,
        title = "Decision Log",
        subtitle = state?.takeIf { !it.isEmpty }?.let {
            "${it.decisions.size} logged · ${it.ownPreferencePercent}% went your way"
        },
        floatingActionButton = {
            val interaction = remember { MutableInteractionSource() }
            ExtendedFloatingActionButton(
                onClick = onCreateDecision,
                modifier = Modifier.pressPhysics(interaction),
                interactionSource = interaction,
                containerColor = MaterialTheme.colorScheme.primaryContainer,
                contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                icon = { Icon(Icons.Filled.Add, contentDescription = null) },
                text = { Text("Log decision") },
            )
        },
    ) { innerPadding ->
        UiStateContent(state = uiState, modifier = Modifier.padding(innerPadding)) { current ->
            if (current.isEmpty) {
                EmptyState(
                    icon = Icons.Outlined.Balance,
                    title = "No decisions logged",
                    message = "Write down what you wanted, what you chose, and - later - " +
                        "how it actually felt. The record is for you, not for anyone else.",
                    actionLabel = "Log a decision",
                    onAction = onCreateDecision,
                )
            } else {
                DecisionList(
                    state = current,
                    onDecisionClick = onDecisionClick,
                    onToggleExpanded = onToggleExpanded,
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DecisionList(
    state: DecisionListState,
    onDecisionClick: (Long) -> Unit,
    onToggleExpanded: (Long) -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 104.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item(key = "summary") { SelfTrustSummary(state, Modifier.animateItem()) }
        items(state.decisions, key = { it.id }) { decision ->
            DecisionCard(
                decision = decision,
                expanded = decision.id in state.expandedIds,
                onClick = { onDecisionClick(decision.id) },
                onToggleExpanded = { onToggleExpanded(decision.id) },
                modifier = Modifier.animateItem(),
            )
        }
    }
}

/** A quiet, non-judgemental tally at the top of the log. */
@Composable
private fun SelfTrustSummary(
    state: DecisionListState,
    modifier: Modifier = Modifier,
) {
    AutonomyCard(
        modifier = modifier,
        containerColor = MaterialTheme.colorScheme.secondaryContainer,
        contentPadding = PaddingValues(20.dp),
    ) {
        Column {
            Text(
                text = "${state.decisions.size} decisions logged",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSecondaryContainer,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = "${state.ownPreferencePercent}% went the way you wanted" +
                    if (state.awaitingReflectionCount > 0) {
                        " · ${state.awaitingReflectionCount} still to reflect on"
                    } else {
                        ""
                    },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSecondaryContainer,
            )
        }
    }
}

/** One journal entry. The reflection is the collapsed part - it is the slow half. */
@Composable
fun DecisionCard(
    decision: Decision,
    expanded: Boolean,
    onClick: () -> Unit,
    onToggleExpanded: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val chevron by animateFloatAsState(
        targetValue = if (expanded) 180f else 0f,
        label = "decisionChevron",
    )
    AutonomyCard(modifier = modifier, contentPadding = PaddingValues(20.dp)) {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(
                    Modifier
                        .weight(1f)
                        .clickable(onClick = onClick),
                ) {
                    Text(text = decision.title, style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.height(6.dp))
                    Text(
                        text = decision.date.formatFull(),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Icon(
                    imageVector = Icons.Filled.ExpandMore,
                    contentDescription = if (expanded) "Collapse entry" else "Expand entry",
                    modifier = Modifier
                        .clickable(onClick = onToggleExpanded)
                        .rotate(chevron),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            Spacer(Modifier.height(12.dp))
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                DecisionCategoryChip(decision.category)
                if (decision.followedOwnPreference) {
                    LabelChip(
                        text = "Your call",
                        containerColor = MaterialTheme.colorScheme.tertiaryContainer,
                        contentColor = MaterialTheme.colorScheme.onTertiaryContainer,
                    )
                }
                if (!decision.hasReflection) {
                    LabelChip("Reflection pending")
                }
            }

            ExpandableContent(expanded = expanded) {
                Column {
                    Spacer(Modifier.height(16.dp))
                    PreferenceRow("Wanted", decision.myPreference)
                    Spacer(Modifier.height(10.dp))
                    PreferenceRow("Chose", decision.finalChoice)
                    Spacer(Modifier.height(10.dp))
                    PreferenceRow(
                        "Felt",
                        decision.reflection.ifBlank { "Not reflected on yet." },
                    )
                }
            }
        }
    }
}

@Composable
private fun PreferenceRow(label: String, value: String) {
    if (value.isBlank()) return
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(56.dp),
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.weight(1f),
        )
    }
}

@ScreenPreviews
@Composable
private fun DecisionListPreview() {
    AutonomyTheme {
        DecisionListContent(
            uiState = UiState.Success(
                DecisionListState(
                    decisions = PreviewData.decisions,
                    expandedIds = setOf(PreviewData.decisions.first().id),
                ),
            ),
            onDecisionClick = {},
            onCreateDecision = {},
            onToggleExpanded = {},
        )
    }
}

@ScreenPreviews
@Composable
private fun DecisionListEmptyPreview() {
    AutonomyTheme {
        DecisionListContent(
            uiState = UiState.Success(DecisionListState()),
            onDecisionClick = {},
            onCreateDecision = {},
            onToggleExpanded = {},
        )
    }
}

@ScreenPreviews
@Composable
private fun DecisionListErrorPreview() {
    AutonomyTheme {
        DecisionListContent(
            uiState = UiState.Error("Could not load your decision log."),
            onDecisionClick = {},
            onCreateDecision = {},
            onToggleExpanded = {},
        )
    }
}
