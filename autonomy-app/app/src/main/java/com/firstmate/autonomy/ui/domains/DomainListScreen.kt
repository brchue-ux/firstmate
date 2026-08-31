package com.firstmate.autonomy.ui.domains

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Handyman
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilterChip
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
import com.firstmate.autonomy.domain.model.DomainStatus
import com.firstmate.autonomy.domain.model.ProjectDomain
import com.firstmate.autonomy.ui.components.DomainStatusChip
import com.firstmate.autonomy.ui.components.EmptyState
import com.firstmate.autonomy.ui.components.LabelChip
import com.firstmate.autonomy.ui.components.LabeledProgress
import com.firstmate.autonomy.ui.preview.PreviewData
import com.firstmate.autonomy.ui.preview.ScreenPreviews
import com.firstmate.autonomy.ui.theme.AutonomyTheme

/** "My Domains": every solo project, filterable by stage. */
@Composable
fun DomainListScreen(
    onDomainClick: (Long) -> Unit,
    onCreateDomain: () -> Unit,
    modifier: Modifier = Modifier,
    viewModel: DomainListViewModel = viewModel(factory = AutonomyViewModelFactory.Factory),
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DomainListContent(
    uiState: DomainListUiState,
    onFilterChange: (DomainStatus?) -> Unit,
    onDomainClick: (Long) -> Unit,
    onCreateDomain: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Scaffold(
        modifier = modifier,
        // The app-level scaffold already handles system bars.
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        topBar = { TopAppBar(title = { Text("My Domains") }) },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = onCreateDomain,
                icon = { Icon(Icons.Filled.Add, contentDescription = null) },
                text = { Text("New project") },
            )
        },
    ) { innerPadding ->
        Box(Modifier.padding(innerPadding)) {
            when {
                uiState.isLoading -> Unit // The first frame from a local database is immediate.

                uiState.isEmpty -> EmptyState(
                    icon = Icons.Outlined.Handyman,
                    title = "No projects yet",
                    message = "Domains are the things you own end to end - a workshop build, " +
                        "a technical setup, a skill you are practising. Add the first one.",
                    actionLabel = "New project",
                    onAction = onCreateDomain,
                )

                else -> Column(Modifier.fillMaxSize()) {
                    StatusFilterRow(
                        selected = uiState.filter,
                        onFilterChange = onFilterChange,
                    )
                    if (uiState.isFilteredEmpty) {
                        EmptyState(
                            icon = Icons.Outlined.Handyman,
                            title = "Nothing here",
                            message = "No projects are marked " +
                                "\"${uiState.filter?.label.orEmpty()}\" right now.",
                            actionLabel = "Show all",
                            onAction = { onFilterChange(null) },
                        )
                    } else {
                        LazyColumn(
                            modifier = Modifier.fillMaxSize(),
                            contentPadding = PaddingValues(
                                start = 16.dp,
                                end = 16.dp,
                                top = 4.dp,
                                // Clears the extended FAB.
                                bottom = 96.dp,
                            ),
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            items(uiState.domains, key = { it.id }) { domain ->
                                DomainCard(
                                    domain = domain,
                                    onClick = { onDomainClick(domain.id) },
                                )
                            }
                        }
                    }
                }
            }
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
        FilterChip(
            selected = selected == null,
            onClick = { onFilterChange(null) },
            label = { Text("All") },
        )
        DomainStatus.entries.forEach { status ->
            FilterChip(
                selected = selected == status,
                onClick = { onFilterChange(status) },
                label = { Text(status.label) },
            )
        }
    }
}

/** One project summary: title, category, stage, and milestone-derived progress. */
@Composable
fun DomainCard(
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
        Column(Modifier.padding(16.dp)) {
            Text(
                text = domain.title,
                style = MaterialTheme.typography.titleMedium,
            )
            Spacer(Modifier.height(10.dp))
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                DomainStatusChip(domain.status)
                LabelChip(domain.category)
            }
            Spacer(Modifier.height(14.dp))
            LabeledProgress(
                label = if (domain.milestoneCount == 0) "No milestones yet" else "Milestones",
                progress = domain.progress,
                trailingText = if (domain.milestoneCount == 0) {
                    "${domain.progressPercent}%"
                } else {
                    "${domain.completedMilestoneCount} of ${domain.milestoneCount}"
                },
                accessibilityText = "${domain.title}, ${domain.status.label}, " +
                    "${domain.progressPercent} percent complete",
            )
        }
    }
}

@ScreenPreviews
@Composable
private fun DomainListPreview() {
    AutonomyTheme {
        DomainListContent(
            uiState = DomainListUiState(
                isLoading = false,
                domains = PreviewData.domains,
                totalCount = PreviewData.domains.size,
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
            uiState = DomainListUiState(isLoading = false),
            onFilterChange = {},
            onDomainClick = {},
            onCreateDomain = {},
        )
    }
}
