package com.firstmate.autonomy.ui.domains

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Handyman
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.firstmate.autonomy.domain.model.DomainStatus
import com.firstmate.autonomy.domain.model.ProjectDomain
import com.firstmate.autonomy.ui.common.UiState
import com.firstmate.autonomy.ui.common.UiStateContent
import com.firstmate.autonomy.ui.components.AutonomyCard
import com.firstmate.autonomy.ui.components.CollapsingScaffold
import com.firstmate.autonomy.ui.components.DomainStatusChip
import com.firstmate.autonomy.ui.components.EmptyState
import com.firstmate.autonomy.ui.components.LabelChip
import com.firstmate.autonomy.ui.components.ProgressRing
import com.firstmate.autonomy.ui.components.pressPhysics
import com.firstmate.autonomy.ui.preview.PreviewData
import com.firstmate.autonomy.ui.preview.ScreenPreviews
import com.firstmate.autonomy.ui.theme.AutonomyTheme

/** "My Domains": every solo project, filterable by stage. */
@Composable
fun DomainListScreen(
    onDomainClick: (Long) -> Unit,
    onCreateDomain: () -> Unit,
    modifier: Modifier = Modifier,
    viewModel: DomainListViewModel = hiltViewModel(),
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    DomainListContent(
        uiState = uiState,
        onFilterChange = viewModel::setFilter,
        onDomainClick = onDomainClick,
        onCreateDomain = onCreateDomain,
        modifier = modifier,
    )
}

@Composable
fun DomainListContent(
    uiState: UiState<DomainListState>,
    onFilterChange: (DomainStatus?) -> Unit,
    onDomainClick: (Long) -> Unit,
    onCreateDomain: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val summary = uiState.dataOrNull
    CollapsingScaffold(
        modifier = modifier,
        title = "My Domains",
        subtitle = summary?.let { state ->
            when {
                state.isEmpty -> null
                else -> "${state.totalCount} project(s) · " +
                    "${(state.averageProgress * 100).toInt()}% average completion"
            }
        },
        floatingActionButton = {
            val interaction = remember { MutableInteractionSource() }
            ExtendedFloatingActionButton(
                onClick = onCreateDomain,
                modifier = Modifier.pressPhysics(interaction),
                interactionSource = interaction,
                containerColor = MaterialTheme.colorScheme.primaryContainer,
                contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                icon = { Icon(Icons.Filled.Add, contentDescription = null) },
                text = { Text("New project") },
            )
        },
    ) { innerPadding, _ ->
        UiStateContent(state = uiState, modifier = Modifier.padding(innerPadding)) { state ->
            when {
                state.isEmpty -> EmptyState(
                    icon = Icons.Outlined.Handyman,
                    title = "No projects yet",
                    message = "Domains are the things you own end to end - a workshop build, " +
                        "a technical setup, a skill you are practising. Add the first one.",
                    actionLabel = "New project",
                    onAction = onCreateDomain,
                )

                else -> Column(Modifier.fillMaxSize()) {
                    StatusFilterRow(selected = state.filter, onFilterChange = onFilterChange)
                    if (state.isFilteredEmpty) {
                        EmptyState(
                            icon = Icons.Outlined.Handyman,
                            title = "Nothing here",
                            message = "No projects are marked " +
                                "\"${state.filter?.label.orEmpty()}\" right now.",
                            actionLabel = "Show all",
                            onAction = { onFilterChange(null) },
                        )
                    } else {
                        DomainList(state = state, onDomainClick = onDomainClick)
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DomainList(
    state: DomainListState,
    onDomainClick: (Long) -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(
            start = 16.dp,
            end = 16.dp,
            top = 4.dp,
            // Clears the extended FAB.
            bottom = 104.dp,
        ),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        items(state.domains, key = { it.id }) { domain ->
            DomainCard(
                domain = domain,
                onClick = { onDomainClick(domain.id) },
                // Filtering and reordering animate rather than snapping.
                modifier = Modifier.animateItem(),
            )
        }
    }
}

@Composable
private fun StatusFilterRow(
    selected: DomainStatus?,
    onFilterChange: (DomainStatus?) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        AutonomyFilterChip(
            selected = selected == null,
            label = "All",
            onClick = { onFilterChange(null) },
        )
        DomainStatus.entries.forEach { status ->
            AutonomyFilterChip(
                selected = selected == status,
                label = status.label,
                onClick = { onFilterChange(status) },
            )
        }
    }
}

@Composable
private fun AutonomyFilterChip(
    selected: Boolean,
    label: String,
    onClick: () -> Unit,
) {
    FilterChip(
        selected = selected,
        onClick = onClick,
        label = { Text(label) },
        colors = FilterChipDefaults.filterChipColors(
            selectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
            selectedLabelColor = MaterialTheme.colorScheme.onPrimaryContainer,
        ),
    )
}

/** One project: ring on the left, identity and stage on the right. */
@Composable
fun DomainCard(
    domain: ProjectDomain,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val accent by animateColorAsState(
        targetValue = AutonomyTheme.accents.forStatus(domain.status),
        label = "cardAccent",
    )
    AutonomyCard(modifier = modifier.clickable(onClick = onClick)) {
        Row(
            modifier = Modifier.padding(20.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ProgressRing(
                progress = domain.progress,
                size = 76.dp,
                strokeWidth = 9.dp,
                color = accent,
                contentDescriptionText = "${domain.title}, ${domain.status.label}, " +
                    "${domain.progressPercent} percent complete",
            )
            Spacer(Modifier.width(18.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    text = domain.title,
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 2,
                )
                Spacer(Modifier.height(10.dp))
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    DomainStatusChip(domain.status)
                    LabelChip(domain.category)
                }
                Spacer(Modifier.height(8.dp))
                Text(
                    text = if (domain.milestoneCount == 0) {
                        "No milestones yet"
                    } else {
                        "${domain.completedMilestoneCount} of ${domain.milestoneCount} milestones"
                    },
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@ScreenPreviews
@Composable
private fun DomainListPreview() {
    AutonomyTheme {
        DomainListContent(
            uiState = UiState.Success(
                DomainListState(
                    domains = PreviewData.domains,
                    totalCount = PreviewData.domains.size,
                ),
            ),
            onFilterChange = {},
            onDomainClick = {},
            onCreateDomain = {},
        )
    }
}

@ScreenPreviews
@Composable
private fun DomainListEmptyPreview() {
    AutonomyTheme {
        DomainListContent(
            uiState = UiState.Success(DomainListState()),
            onFilterChange = {},
            onDomainClick = {},
            onCreateDomain = {},
        )
    }
}

@ScreenPreviews
@Composable
private fun DomainListLoadingPreview() {
    AutonomyTheme {
        DomainListContent(
            uiState = UiState.Loading,
            onFilterChange = {},
            onDomainClick = {},
            onCreateDomain = {},
        )
    }
}

@ScreenPreviews
@Composable
private fun DomainListErrorPreview() {
    AutonomyTheme {
        DomainListContent(
            uiState = UiState.Error("Could not load your projects."),
            onFilterChange = {},
            onDomainClick = {},
            onCreateDomain = {},
        )
    }
}

/** Standalone card preview - the fastest loop when iterating on the ring. */
@ScreenPreviews
@Composable
private fun DomainCardPreview() {
    AutonomyTheme {
        Column(
            Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            PreviewData.domains.forEach { DomainCard(it, onClick = {}) }
        }
    }
}
