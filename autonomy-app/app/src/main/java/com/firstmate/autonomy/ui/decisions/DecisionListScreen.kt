package com.firstmate.autonomy.ui.decisions

import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Balance
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.firstmate.autonomy.di.AutonomyViewModelFactory
import com.firstmate.autonomy.domain.model.Decision
import com.firstmate.autonomy.ui.components.DecisionCategoryChip
import com.firstmate.autonomy.ui.components.EmptyState
import com.firstmate.autonomy.ui.components.LabelChip
import com.firstmate.autonomy.ui.preview.PreviewData
import com.firstmate.autonomy.ui.preview.ScreenPreviews
import com.firstmate.autonomy.ui.preview.ThemePreviews
import com.firstmate.autonomy.ui.theme.AutonomyTheme
import com.firstmate.autonomy.ui.util.formatFull

/** "Decision Log": every choice made, owned and reflected on. */
@Composable
fun DecisionListScreen(
    onDecisionClick: (Long) -> Unit,
    onCreateDecision: () -> Unit,
    modifier: Modifier = Modifier,
    viewModel: DecisionListViewModel = viewModel(factory = AutonomyViewModelFactory.Factory),
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    DecisionListContent(
        uiState = uiState,
        onDecisionClick = onDecisionClick,
        onCreateDecision = onCreateDecision,
        modifier = modifier,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DecisionListContent(
    uiState: DecisionListUiState,
    onDecisionClick: (Long) -> Unit,
    onCreateDecision: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Scaffold(
        modifier = modifier,
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        topBar = { TopAppBar(title = { Text("Decision Log") }) },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = onCreateDecision,
                icon = { Icon(Icons.Filled.Add, contentDescription = null) },
                text = { Text("Log decision") },
            )
        },
    ) { innerPadding ->
        Box(Modifier.padding(innerPadding)) {
            when {
                uiState.isLoading -> Unit

                uiState.isEmpty -> EmptyState(
                    icon = Icons.Outlined.Balance,
                    title = "No decisions logged",
                    message = "Write down what you wanted, what you chose, and - later - " +
                        "how it actually felt. The record is for you, not for anyone else.",
                    actionLabel = "Log a decision",
                    onAction = onCreateDecision,
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
                    item { SelfTrustSummary(uiState) }
                    items(uiState.decisions, key = { it.id }) { decision ->
                        DecisionCard(
                            decision = decision,
                            onClick = { onDecisionClick(decision.id) },
                        )
                    }
                }
            }
        }
    }
}

/** A quiet, non-judgemental tally at the top of the log. */
@Composable
private fun SelfTrustSummary(
    uiState: DecisionListUiState,
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
                text = "${uiState.decisions.size} decisions logged",
                style = MaterialTheme.typography.titleMedium,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = "${uiState.ownPreferencePercent}% went the way you wanted" +
                    if (uiState.awaitingReflectionCount > 0) {
                        " · ${uiState.awaitingReflectionCount} still to reflect on"
                    } else {
                        ""
                    },
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}

/** One journal entry: what was wanted, what happened, and whether it has been reflected on. */
@Composable
fun DecisionCard(
    decision: Decision,
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
        Column(Modifier.padding(16.dp)) {
            Text(text = decision.title, style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(6.dp))
            Text(
                text = decision.date.formatFull(),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(10.dp))
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                DecisionCategoryChip(decision.category)
                if (decision.followedOwnPreference) {
                    LabelChip("Your call")
                }
                if (!decision.hasReflection) {
                    LabelChip("Reflection pending")
                }
            }
            if (decision.myPreference.isNotBlank() || decision.finalChoice.isNotBlank()) {
                Spacer(Modifier.height(12.dp))
                PreferenceRow("Wanted", decision.myPreference)
                Spacer(Modifier.height(6.dp))
                PreferenceRow("Chose", decision.finalChoice)
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
            maxLines = 2,
            modifier = Modifier.weight(1f),
        )
    }
}

@ScreenPreviews
@Composable
private fun DecisionListPreview() {
    AutonomyTheme {
        DecisionListContent(
            uiState = DecisionListUiState(isLoading = false, decisions = PreviewData.decisions),
            onDecisionClick = {},
            onCreateDecision = {},
        )
    }
}

@ScreenPreviews
@Composable
private fun DecisionListEmptyPreview() {
    AutonomyTheme {
        DecisionListContent(
            uiState = DecisionListUiState(isLoading = false),
            onDecisionClick = {},
            onCreateDecision = {},
        )
    }
}

@ThemePreviews
@Composable
private fun DecisionCardPreview() {
    AutonomyTheme {
        Column(
            Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            PreviewData.decisions.take(2).forEach { DecisionCard(it, onClick = {}) }
        }
    }
}
